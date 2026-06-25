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

## Redeploy after the developer pushes changes

```bash
ssh -t user1@139.162.170.253 'sudo git -C /opt/torama.money/site pull --ff-only'
```

(No restart needed — nginx serves the files live. Re-running the full script also works.)

## If something fails

Paste the script output back to me. Useful logs:
`/var/log/apache2/torama.money-error.log`, `docker logs torama-money`, `/var/log/letsencrypt/letsencrypt.log`.
