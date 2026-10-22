#!/usr/bin/env bash
# Integration tests that run a REAL nginx and a REAL MariaDB/MySQL server as an ordinary user
# (no root, no docker, no systemd, ports 18080/18443). Needs: nginx, mariadbd/mysqld, openssl, curl, rsync.
set -uo pipefail
cd "$(dirname "$0")/.."
export NO_COLOR=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
source tests/env.sh
SITE=shop.example.test

echo "== init-site"
out=$($WSK init-site $SITE --self-signed --http-port 18080 --https-port 18443 2>&1); rc=$?
assert "init-site succeeds"                           '(( rc == 0 ))'
assert "nginx -t passed inside init-site"             'grep -q "nginx config test passed" <<<"$out"'
assert "credentials file is mode 600"                 '[[ $(stat -c %a "$WSK_ETC/sites/$SITE.my.cnf") == 600 ]]'
assert "vhost has TLS1.2+1.3 only"                    'grep -q "ssl_protocols TLSv1.2 TLSv1.3" "$WSK_NGINX_CONFD/$SITE.conf"'
"$T/nginx-wrap" || { echo "nginx failed to start"; cat "$T/nginx/logs/error.log"; exit 3; }
sleep 1
H="--resolve $SITE:18080:127.0.0.1 --resolve $SITE:18443:127.0.0.1"
assert "HTTP redirects to HTTPS (301)"                '[[ $(curl -s -o /dev/null -w "%{http_code}" $H http://$SITE:18080/) == 301 ]]'
assert "HTTPS serves the page (200)"                  '[[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18443/) == 200 ]]'
hdr=$(curl -skI $H https://$SITE:18443/ | tr -d "\r")
assert "security headers present"                     'grep -qi "x-content-type-options: nosniff" <<<"$hdr" && grep -qi "content-security-policy" <<<"$hdr"'
assert "nginx version hidden (server_tokens off)"     '! grep -qi "nginx/[0-9]" <<<"$hdr"'
assert "dotfiles are blocked (/.env -> 403)"          'echo secret > "$WSK_WEBROOT_BASE/$SITE/public/.env"; [[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18443/.env) == 403 ]]'
assert "old TLS 1.1 is refused"                       '! curl -sk --tls-max 1.1 -o /dev/null $H https://$SITE:18443/ 2>/dev/null'
assert "app DB user cannot see other databases"       '[[ -z $($CLI --defaults-extra-file="$WSK_ETC/sites/$SITE.my.cnf" -S $T/s.sock -N -e "SHOW DATABASES" 2>&1 | grep -x mysql) ]]'
hout=$($WSK health 2>&1)
assert "health check passes end-to-end"               'grep -q "https answers 200" <<<"$hout" && grep -q "http -> https redirect" <<<"$hout" && grep -q "nginx configuration valid" <<<"$hout"'

echo "== backup / verify / restore"
$CLI -S $T/s.sock -uroot -e "INSERT INTO shop_example_test.visits(path) VALUES ('/a'),('/b'),('/c')"
$WSK backup >"$T/b1.log" 2>&1; rc=$?
assert "backup succeeds"                              '(( rc == 0 ))'
B=$(ls -d "$WSK_BACKUP_DIR"/daily/*/ | head -1)
assert "backup holds sql.gz + files + checksums + manifest" '[[ -s $B/$SITE.db.sql.gz && -s $B/$SITE.files.tar.gz && -s $B/SHA256SUMS && -s $B/manifest.json ]]'
assert "backup directory is private (700)"            '[[ $(stat -c %a "$WSK_BACKUP_DIR") == 700 ]]'
out=$($WSK verify 2>&1); rc=$?
assert "verify = real restore into scratch DB passes" '(( rc == 0 )) && grep -q "row counts match" <<<"$out"'
assert "scratch databases are cleaned up"             '! $CLI -S $T/s.sock -uroot -N -e "show databases" | grep -q wsk_verify'
# corrupt the dump and make sure verify notices
cp -a "$B" "$T/B-copy"; echo garbage >> "$T/B-copy/$SITE.db.sql.gz"
out=$($WSK verify "$T/B-copy" 2>&1); rc=$?
assert "verify detects a corrupted backup"            '(( rc == 1 )) && grep -q "checksum mismatch" <<<"$out"'
rm -rf "$T/B-copy"
# disaster: drop the table and restore
$CLI -S $T/s.sock -uroot -e "DROP TABLE shop_example_test.visits"; rm -rf "$WSK_WEBROOT_BASE/$SITE/public/index.html"
assert "restore refuses without --yes"               '! $WSK restore "$B" $SITE 2>/dev/null'
$WSK restore "$B" $SITE --yes >/dev/null 2>&1
assert "restore brings the data back (3 rows)"        '[[ $($CLI -S $T/s.sock -uroot -N -e "select count(*) from shop_example_test.visits") == 3 ]]'
assert "restore brings the web files back"            '[[ -s $WSK_WEBROOT_BASE/$SITE/public/index.html ]]'

echo "== retention (GFS)"
export WSK_DAILY_KEEP=3
for i in 1 2 3 4 5; do sleep 1.1; $WSK backup >/dev/null 2>&1; done
assert "daily retention keeps only 3"                 '[[ $(ls "$WSK_BACKUP_DIR/daily" | wc -l) == 3 ]]'
WSK_FORCE_PROMOTE=weekly,monthly $WSK backup >/dev/null 2>&1
assert "weekly + monthly promotion created"           '[[ -d $WSK_BACKUP_DIR/weekly && -d $WSK_BACKUP_DIR/monthly ]]'
assert "promotion uses hard links (no extra space)"   'W=$(ls -d $WSK_BACKUP_DIR/weekly/*/ | head -1); [[ $(stat -c %h "$W/SHA256SUMS") -ge 2 ]]'
export WSK_RSYNC_TARGET="$T/offsite"; mkdir -p "$T/offsite"
$WSK backup >/dev/null 2>&1
assert "off-site rsync copy is identical"             'diff -r "$WSK_BACKUP_DIR" "$T/offsite" >/dev/null'
unset WSK_RSYNC_TARGET

echo "== certificates"
out=$($WSK certs); rc=$?
assert "certs table shows the site, 89-90 days left"  'grep -Eq "$SITE .*self-signed +(89|90)" <<<"$out" && (( rc == 0 ))'
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -keyout "$WSK_ETC/certs/$SITE/privkey.pem" -out "$WSK_ETC/certs/$SITE/fullchain.pem" -subj "/CN=$SITE" 2>/dev/null
out=$($WSK certs); rc=$?
assert "3-day certificate is flagged CRITICAL (exit 2)" 'grep -q CRITICAL <<<"$out" && (( rc == 2 ))'
$WSK certs renew $SITE >/dev/null 2>&1
out=$($WSK certs); rc=$?
assert "certs renew regenerates it (exit 0)"          '(( rc == 0 ))'

echo "== logs / logrotate / timers"
LOG="$T/log/$SITE.access.log"
{ for i in $(seq 1 30); do echo "198.51.100.$((i%3+1)) - - [22/Oct/2026:10:00:00 +0000] \"GET /index.html HTTP/1.1\" 200 512 \"-\" \"curl\" rt=0.00$i"; done
  for p in /wp-login.php /.env /phpmyadmin/ /.git/config; do echo "203.0.113.66 - - [22/Oct/2026:10:01:00 +0000] \"GET $p HTTP/1.1\" 404 150 \"-\" \"scanner\" rt=0.001"; done; } > "$LOG"
out=$($WSK logs "$LOG")
assert "log report finds the scanner IP"              'grep -q "203.0.113.66 *4 probes" <<<"$out"'
assert "log report counts status codes"               'grep -Eq "200 +30" <<<"$out" && grep -Eq "404 +4" <<<"$out"'
$WSK logrotate >/dev/null 2>&1
assert "logrotate policy written"                     'grep -q "rotate 8" "$WSK_LOGROTATE_FILE" && grep -q "compress" "$WSK_LOGROTATE_FILE"'
if command -v logrotate >/dev/null; then
  lr=$(logrotate -d "$WSK_LOGROTATE_FILE" 2>&1)
  assert "logrotate accepts the policy (logrotate -d, no syntax errors)" 'grep -q "reading config file" <<<"$lr" && ! grep -qiE "unknown option|bad |syntax|unexpected" <<<"$lr"'
else echo "  skip logrotate -d (logrotate not installed here; CI runs it)"; fi
tout=$($WSK timers)
assert "timers cron file contains all 4 jobs"         '[[ $(grep -c " root " <<<"$tout") -eq 4 ]]'

echo "== health when something breaks"
"$T/nginx-wrap" -s stop; sleep 1
out=$($WSK health 2>&1); rc=$?
assert "health reports FAIL (exit 2) when nginx is down" '(( rc == 2 )) && grep -q "https returned" <<<"$out"'

echo "== broken-config drill"
cp "$WSK_NGINX_CONFD/$SITE.conf" "$T/vhost.bak"
echo "this is not valid nginx config ;;;" >> "$WSK_NGINX_CONFD/$SITE.conf"
out=$($WSK health 2>&1); rc=$?
assert "health FAILS (exit 2) on a broken nginx vhost"  '(( rc == 2 )) && grep -q "nginx -t" <<<"$out"'
cp "$T/vhost.bak" "$WSK_NGINX_CONFD/$SITE.conf"

echo "== scheduled jobs: guarded cron file, validation, overlap/timeout protection"
$WSK timers --apply >/dev/null
assert "timers --apply wrote a cron file with 4 guarded jobs"  '[[ $(grep -c " guard " "$WSK_CRON_FILE") == 4 ]] && grep -q "^MAILTO=" "$WSK_CRON_FILE"'
out=$($WSK timers --check); rc=$?
assert "timers --check accepts the generated file"             '(( rc == 0 )) && grep -q "is valid" <<<"$out"'
cp "$WSK_CRON_FILE" "$T/cron.bad"; sed -i 's|^30 2 \* \* \*|61 2 * * *|' "$T/cron.bad"; echo '0 1 * * * root /nonexistent/wsk backup' >> "$T/cron.bad"; echo '0 1 * * * nosuchuser '"$PWD/wsk"' backup' >> "$T/cron.bad"; echo '0 1 * * * root '"$PWD"'/wsk logs date +%F' >> "$T/cron.bad"
out=$($WSK timers --check "$T/cron.bad"); rc=$?
assert "check catches bad schedule, missing binary, unknown user, unescaped %" '(( rc == 2 )) && grep -q "invalid schedule" <<<"$out" && grep -q "not an executable" <<<"$out" && grep -q "does not exist" <<<"$out" && grep -q "unescaped %" <<<"$out"'
$WSK guard okjob 20 version >/dev/null; rc=$?
assert "guard: success logged, rc 0"                           '(( rc == 0 )) && grep -q "okjob end rc=0" "$WSK_ETC/okjob.log"'
$WSK guard backup 20 restore /nonexistent nosite --yes >/dev/null 2>&1; rc=$?
assert "guard: failing job returns non-zero and records it"    '(( rc != 0 )) && grep -q "^rc=$rc" "$WSK_ETC/status/backup"'
out=$($WSK timers --status); rc=$?
assert "timers --status flags the failed job (exit 2)"         '(( rc == 2 )) && grep -q "never-run" <<<"$out"'
out=$($WSK health 2>&1)
assert "health reports the failed scheduled job"               'grep -q "scheduled job .backup. last exited" <<<"$out"'
rm -f "$WSK_ETC/status/backup"
( flock "$WSK_ETC/locks/health.lock" sleep 3 & ); sleep 0.7
$WSK guard health 20 version >/dev/null; rc=$?
assert "guard: overlapping run skipped quietly (rc 0)"         '(( rc == 0 )) && grep -q "health skipped, previous run still active" "$WSK_ETC/health.log"'
sleep 3.2
printf '#!/bin/sh\nsleep 30\n' > "$T/slowsql"; chmod +x "$T/slowsql"
WSK_MYSQL="$T/slowsql" $WSK guard health 2 health >/dev/null 2>&1; rc=$?
assert "guard: a hung job is killed by the timeout (rc 124)"   '(( rc == 124 ))'
rm -f "$WSK_ETC/status/health"
$WSK guard health 20 version >/dev/null
assert "guard: lock is free again after a killed job"          'flock -n "$WSK_ETC/locks/health.lock" true'
$WSK timers --remove >/dev/null
assert "timers --remove deletes the cron file"                 '[[ ! -e $WSK_CRON_FILE ]]'

echo "== storage awareness in wsk health"
printf 'md0 : active raid1 sdb1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n' > "$T/mdstat"
out=$(WSK_MDSTAT="$T/mdstat" $WSK health 2>&1); rc=$?
assert "degraded RAID makes health FAIL (exit 2)"              '(( rc == 2 )) && grep -q "software RAID problem: md0(degraded 1/2)" <<<"$out"'
printf 'md0 : active raid1 sdc1[1] sdb1[0]\n      1046528 blocks super 1.2 [2/2] [UU]\n' > "$T/mdstat"
out=$(WSK_MDSTAT="$T/mdstat" $WSK health 2>&1)
assert "healthy RAID reported OK"                              'grep -q "software RAID arrays complete" <<<"$out"'
assert "data/backup/web filesystems usage is reported"         'grep -Eq "(ok|OK).*% used|on .* [0-9]+% used" <<<"$out" || grep -q "% used" <<<"$out"'

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
