#!/usr/bin/env bash
# Apache (httpd) integration scenarios - the same production standard as the nginx suite:
# a REAL Apache and a REAL MariaDB, no root, no systemd, ports 18081/18444.
# Needs: apache2/httpd (+mod_ssl), mariadbd/mysqld, openssl, curl.
set -uo pipefail
cd "$(dirname "$0")/.."
export NO_COLOR=1
. tests/env-apache.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
SITE=apache_example_test
H="--resolve $SITE:18081:127.0.0.1 --resolve $SITE:18444:127.0.0.1"

echo "== init-site --server=apache"
out=$($WSK init-site $SITE --self-signed --http-port 18081 --https-port 18444 --server apache 2>&1)
assert "apache configtest passed inside init-site"   'grep -q "apache configtest passed" <<<"$out"'
assert "vhost + global snippet written"              '[[ -s $WSK_APACHE_CONFD/$SITE.conf && -s $WSK_APACHE_CONFD/00-wsk-global.conf ]]'
assert "least-privilege DB user + 600 credentials"   '[[ $(stat -c %a "$WSK_ETC/sites/$SITE.my.cnf") == 600 ]] && grep -q "apache_example_test_app" "$WSK_ETC/sites/$SITE.my.cnf"'
assert "site env records SERVER=apache"              'grep -q "^SERVER=apache$" "$WSK_ETC/sites/$SITE.env"'

"$T/apache-wrap" || { echo "apache failed to start"; cat "$T/apache/logs/error.log"; exit 3; }
for _ in $(seq 1 30); do curl -sk -o /dev/null $H https://$SITE:18444/ 2>/dev/null && break; sleep 0.3; done

echo "== HTTP behaviour (same standard as nginx)"
assert "HTTP redirects to HTTPS (301)"               '[[ $(curl -s -o /dev/null -w "%{http_code}" $H http://$SITE:18081/) == 301 ]]'
assert "HTTPS serves the page (200)"                 '[[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18444/) == 200 ]]'
hdr=$(curl -skI $H https://$SITE:18444/ | tr -d "\r")
assert "security headers present (nosniff, CSP...)"  'grep -qi "x-content-type-options: nosniff" <<<"$hdr" && grep -qi "content-security-policy" <<<"$hdr"'
assert "apache version hidden (ServerTokens Prod)"   'grep -iq "^server: Apache$" <<<"$hdr"'
echo secret > "$WSK_WEBROOT_BASE/$SITE/public/.env"
assert "dotfiles are blocked (/.env -> 403)"         '[[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18444/.env) == 403 ]]'
mkdir -p "$WSK_WEBROOT_BASE/$SITE/public/.git"; echo x > "$WSK_WEBROOT_BASE/$SITE/public/.git/config"
assert "dot-directories blocked (/.git/config)"      '[[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18444/.git/config) == 403 ]]'
echo x > "$WSK_WEBROOT_BASE/$SITE/public/dump.sql"
assert "sql leftovers blocked (/dump.sql -> 403)"    '[[ $(curl -sk -o /dev/null -w "%{http_code}" $H https://$SITE:18444/dump.sql) == 403 ]]'
assert "old TLS 1.1 is refused"                      '! curl -sk --tls-max 1.1 -o /dev/null $H https://$SITE:18444/ 2>/dev/null'
assert "ACME challenge path stays on HTTP (no redirect loop)" 'mkdir -p "$WSK_WEBROOT_BASE/$SITE/public/.well-known/acme-challenge"; echo tok > "$WSK_WEBROOT_BASE/$SITE/public/.well-known/acme-challenge/t"; [[ $(curl -s $H http://$SITE:18081/.well-known/acme-challenge/t) == tok ]]'

echo "== backup captures the apache vhost; verify proves restore"
$WSK backup >/dev/null 2>&1
assert "backup captures the apache vhost"            'ls "$WSK_BACKUP_DIR"/daily/*/*.apache.conf >/dev/null 2>&1'
out=$($WSK verify 2>&1)
assert "verify passes (real restore, row counts)"    'grep -q "row counts match" <<<"$out"'

echo "== health, then the broken-config drill"
out=$($WSK health 2>&1); rc=$?
assert "health passes end-to-end on apache"          '(( rc == 0 )) && grep -q "apache configtest passed" <<<"$out" && grep -q "https answers 200" <<<"$out"'
echo "this is not valid apache config ;;;" >> "$WSK_APACHE_CONFD/$SITE.conf"
out=$($WSK health 2>&1); rc=$?
assert "health FAILS (exit 2) on a broken vhost"     '(( rc == 2 )) && grep -qi "apache configtest failed" <<<"$out"'
sed -i '$d' "$WSK_APACHE_CONFD/$SITE.conf"
out=$($WSK health 2>&1); rc=$?
assert "health passes again after the config is fixed" '(( rc == 0 ))'

echo "== logs (apache access log, same wsk format)"
LOG="$T/apache/logs/$SITE.access.log"
{ for i in $(seq 1 20); do echo "198.51.100.$((i%3+1)) - - [22/Oct/2026:10:00:00 +0000] \"GET /index.html HTTP/1.1\" 200 512 \"-\" \"curl\" rt=0"; done
  for p in /wp-login.php /.env; do echo "203.0.113.66 - - [22/Oct/2026:10:01:00 +0000] \"GET $p HTTP/1.1\" 404 150 \"-\" \"scanner\" rt=0"; done; } >> "$LOG"
out=$($WSK logs "$LOG")
assert "log report finds the scanner IP on apache logs" 'grep -q "203.0.113.66 *2 probes" <<<"$out"'

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
