# Container lab (docker compose)

A self-contained lab version of the stack: **nginx** (TLS, security headers, HTTP->HTTPS redirect),
**MariaDB**, and a **backup sidecar** that writes timestamped, checksummed dumps.
The host tool (`../wsk`) is the production version; this lab is for trying the shape of the
stack without touching a server. It is started and verified on every push by CI (`compose-lab` job).

## Run it

```bash
cd examples
openssl rand -base64 24 > db_password.txt
openssl rand -base64 24 > db_root_password.txt
./gen-certs.sh                 # self-signed lab cert
docker compose up -d --wait
```

Try it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/     # 301 (redirect to HTTPS)
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/   # 200
curl -skI https://localhost:8443/ | grep -i x-content-type-options  # nosniff
docker compose exec backup /backup.sh                               # on-demand backup
ls backups/                                                          # .sql.gz + SHA256SUMS
```

Prove a backup restores (the wsk rule: a backup you never restored is a hope, not a backup):

```bash
docker compose exec db sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" -e "CREATE DATABASE restorecheck"'
zcat backups/shop-*.sql.gz | tail -n +1 | docker compose exec -T db sh -c 'mariadb -uroot -p"$(cat /run/secrets/db_root_password)" restorecheck'
```

Stop and wipe: `docker compose down -v`
