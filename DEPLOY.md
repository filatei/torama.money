# Deploy torama.money → 139.162.170.253

One script does everything: clones `filatei/torama.money` into `/opt/torama.money/site`,
runs it in its own Docker container (nginx, bound to localhost only), adds an isolated
Apache vhost that reverse-proxies to it, and issues a Let's Encrypt cert with HTTPS redirect.

## Run it

```bash
scp setup-torama-server.sh user1@139.162.170.253:~/
ssh -t user1@139.162.170.253 'sudo bash ~/setup-torama-server.sh'
```

(`-t` lets sudo prompt for your password.)

Private repo? Add the server's SSH key as a GitHub deploy key, then:

```bash
ssh -t user1@139.162.170.253 'sudo GIT_URL=git@github.com:filatei/torama.money.git bash ~/setup-torama-server.sh'
```

## Safety / isolation

- Aborts before changing anything if DNS doesn't point at the server.
- Container binds to `127.0.0.1:<free port 8090+>` only — can't collide with other sites' ports.
- Writes only `/opt/torama.money/` and `/etc/apache2/sites-available/torama.money.conf`; never edits other vhosts or containers.
- `apache2ctl configtest` must pass before any reload, otherwise it stops with other sites untouched.
- Cert is scoped with `--cert-name torama.money` (`www.` included only if its DNS resolves).
- Ends by checking otuburu.money and vote.torama.money still respond, plus a renewal dry-run.

## Redeploy after editing the site files

nginx serves from `/opt/torama.money/www` (read-only volume). The site is *not*
pulled from git — copy the files up and fix permissions (mode 644, or the nginx
container can't read them → **403 Forbidden**):

```bash
cd "/Users/user1/Documents/Claude/Projects/TORAM.MONEY/TORAMA.MONEY WEBSITE"
scp index.html terms.html privacy.html logo.svg user1@139.162.170.253:/tmp/
ssh -t user1@139.162.170.253 'sudo install -m644 -o root -g root /tmp/index.html /tmp/terms.html /tmp/privacy.html /tmp/logo.svg /opt/torama.money/www/'
```

(No restart needed — nginx serves the files live.)

> The git repo (`filatei/torama.money`) is for source control only; the server
> does not deploy from it. Always run the scp step above to publish changes.

## If something fails

Paste the script output back to me. Useful logs:
`/var/log/apache2/torama.money-error.log`, `docker logs torama-money`, `/var/log/letsencrypt/letsencrypt.log`.
