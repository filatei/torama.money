#!/usr/bin/env bash
#
# setup-torama-server.sh
# Deploys torama.money on 139.162.170.253 following the existing pattern:
#   - site code cloned from git (filatei/torama.money) into /opt/torama.money/site
#   - served by its own Docker container (nginx:alpine)
#   - host Apache reverse-proxies torama.money -> the container
#   - Let's Encrypt (certbot --apache) for HTTPS
#
# Idempotent: safe to re-run (re-running also does a git pull = redeploy).
# Touches ONLY torama.money resources:
#   /opt/torama.money/            (git checkout + compose + nginx conf)
#   /etc/apache2/sites-available/torama.money.conf
#   docker container "torama-money"
# It never edits other vhosts or containers.
#
# Usage (as root):  bash setup-torama-server.sh
# Private repo?     GIT_URL=git@github.com:filatei/torama.money.git bash setup-torama-server.sh
#
set -euo pipefail

DOMAIN="torama.money"
APP_DIR="/opt/torama.money"
SITE_DIR="${APP_DIR}/site"          # git checkout (filatei/torama.money - currently MT5 code, NOT the website)
WEB_ROOT="${APP_DIR}/www"           # what nginx actually serves
CONTAINER="torama-money"
VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"
EMAIL="filatei@gtsng.com"
GIT_URL="${GIT_URL:-https://github.com/filatei/torama.money.git}"

log()  { echo -e "\n==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo bash $0)"

# ---------------------------------------------------------------- discovery
log "Discovery"
command -v docker >/dev/null || die "docker not found - is this the right server?"
command -v apache2ctl >/dev/null || die "apache2 not found (script targets Debian/Ubuntu Apache)"

echo "Existing site containers:"
docker ps --format '  {{.Names}}  {{.Ports}}' || true
echo "Enabled Apache sites:"
ls /etc/apache2/sites-enabled/ | sed 's/^/  /'

# Verify DNS points here before touching anything (certbot would fail otherwise)
MYIP=$(curl -4 -s --max-time 10 https://ifconfig.me || true)
DNSIP=$(getent ahostsv4 "$DOMAIN" | awk '{print $1; exit}' || true)
echo "Server IP: ${MYIP:-unknown}   ${DOMAIN} resolves to: ${DNSIP:-NOT RESOLVING}"
if [[ -n "$MYIP" && "$DNSIP" != "$MYIP" ]]; then
  die "${DOMAIN} does not resolve to this server yet. Fix DNS, wait for propagation, re-run."
fi

# ------------------------------------------------------- pick a free port
# Reuse the port if the container already exists; otherwise find a free one.
if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  PORT=$(docker inspect -f '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$CONTAINER" 2>/dev/null || true)
fi
if [[ -z "${PORT:-}" ]]; then
  for p in $(seq 8090 8199); do
    if ! ss -ltn "sport = :$p" | grep -q LISTEN; then PORT=$p; break; fi
  done
fi
[[ -n "${PORT:-}" ]] || die "No free port found in 8090-8199"
log "Using host port 127.0.0.1:${PORT} for the ${CONTAINER} container"

# ----------------------------------------- git checkout (auxiliary, non-fatal)
log "Git checkout -> ${SITE_DIR} (kept alongside; not currently the website)"
mkdir -p "$APP_DIR"
if command -v git >/dev/null; then
  if [[ -d "${SITE_DIR}/.git" ]]; then
    git -C "$SITE_DIR" pull --ff-only || echo "WARNING: git pull failed (continuing)"
  else
    git clone "$GIT_URL" "$SITE_DIR" || echo "WARNING: git clone failed (continuing)"
  fi
fi

# -------------------------------------------------------------- web root
log "Web root -> ${WEB_ROOT}"
mkdir -p "$WEB_ROOT"
# Install index.html if one sits next to this script (scp it alongside).
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [[ -f "${SCRIPT_DIR}/index.html" ]]; then
  cp -f "${SCRIPT_DIR}/index.html" "${WEB_ROOT}/index.html"
  echo "Installed index.html from ${SCRIPT_DIR}"
elif [[ ! -f "${WEB_ROOT}/index.html" ]]; then
  cat > "${WEB_ROOT}/index.html" <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><title>torama.money</title></head>
<body style="font-family:sans-serif;text-align:center;padding-top:20vh">
<h1>torama.money</h1><p>Site coming soon.</p></body></html>
EOF
  echo "No index.html provided - installed a placeholder (replace files in ${WEB_ROOT})"
else
  echo "Keeping existing ${WEB_ROOT}/index.html"
fi

# ---------------------------------------------------------------- container
log "Docker container"
# nginx config: serve the repo, but never expose .git or other dotfiles
cat > "${APP_DIR}/nginx-default.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location ~ /\. { deny all; return 404; }
    location / { try_files $uri $uri/ /index.html; }
}
EOF

cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
  web:
    image: nginx:alpine
    container_name: ${CONTAINER}
    restart: unless-stopped
    ports:
      - "127.0.0.1:${PORT}:80"
    volumes:
      - ${WEB_ROOT}:/usr/share/nginx/html:ro
      - ${APP_DIR}/nginx-default.conf:/etc/nginx/conf.d/default.conf:ro
EOF

cd "$APP_DIR"
if docker compose version >/dev/null 2>&1; then
  docker compose up -d
elif command -v docker-compose >/dev/null 2>&1; then
  docker-compose up -d
else
  # Fallback: plain docker run
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" --restart unless-stopped \
    -p "127.0.0.1:${PORT}:80" \
    -v "${WEB_ROOT}:/usr/share/nginx/html:ro" \
    -v "${APP_DIR}/nginx-default.conf:/etc/nginx/conf.d/default.conf:ro" \
    nginx:alpine
fi

sleep 2
curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null \
  || die "Container is not answering on 127.0.0.1:${PORT}"
echo "Container ${CONTAINER} serving on 127.0.0.1:${PORT}"

# -------------------------------------------------------------- apache vhost
log "Apache vhost (HTTP; certbot adds HTTPS)"
a2enmod -q proxy proxy_http headers >/dev/null

cat > "$VHOST" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:${PORT}/
    ProxyPassReverse / http://127.0.0.1:${PORT}/

    ErrorLog  \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

a2ensite -q "${DOMAIN}.conf" >/dev/null
apache2ctl configtest || die "Apache configtest failed - NOT reloading. Other sites untouched."
systemctl reload apache2
echo "Vhost enabled and Apache reloaded"

# ------------------------------------------------------------- lets encrypt
log "Let's Encrypt"
command -v certbot >/dev/null || die "certbot not found. Install it (snap install --classic certbot OR apt install certbot python3-certbot-apache) and re-run."

CERT_DOMAINS=(-d "$DOMAIN")
# Include www only if it resolves to this server (avoid failing the whole order)
WWWIP=$(getent ahostsv4 "www.${DOMAIN}" | awk '{print $1; exit}' || true)
if [[ -n "$WWWIP" && ( -z "$MYIP" || "$WWWIP" == "$MYIP" ) ]]; then
  CERT_DOMAINS+=(-d "www.${DOMAIN}")
else
  echo "www.${DOMAIN} does not resolve here - certificate will cover ${DOMAIN} only"
fi

certbot --apache "${CERT_DOMAINS[@]}" \
  --redirect --non-interactive --agree-tos -m "$EMAIL" \
  --cert-name "$DOMAIN"

apache2ctl configtest && systemctl reload apache2

# ------------------------------------------------------------------- verify
log "Verification"
echo "- HTTP redirect:"; curl -sI "http://${DOMAIN}/"  | head -n 3
echo "- HTTPS:";         curl -sI "https://${DOMAIN}/" | head -n 3
echo "- Other sites still answering:"
for s in otuburu.money vote.torama.money; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${s}/" || echo FAIL)
  echo "    ${s}: ${code}"
done
echo "- Renewal dry-run:"; certbot renew --cert-name "$DOMAIN" --dry-run >/dev/null && echo "    OK"

log "Done. https://${DOMAIN} is live. Site files: ${WEB_ROOT} (container ${CONTAINER}, port 127.0.0.1:${PORT})"
