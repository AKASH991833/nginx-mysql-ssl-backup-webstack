# shellcheck shell=bash
# Starts a private MariaDB + a private Apache httpd (unprivileged ports 18081/18444) as the current user.
# Sourced by tests/run-apache.sh. Works with Debian/Ubuntu apache2 and RHEL-family httpd.
T=$(mktemp -d); WSK=$PWD/wsk
cleanup() { [[ -f $T/apache/run/httpd.pid ]] && kill "$(cat "$T/apache/run/httpd.pid")" 2>/dev/null; [[ -f $T/mysqld.pid ]] && kill "$(cat "$T/mysqld.pid")" 2>/dev/null; sleep 1; rm -rf "$T"; }
trap cleanup EXIT

APBIN=$(command -v apache2 || command -v httpd || ls /usr/sbin/apache2 /usr/sbin/httpd 2>/dev/null | head -1)
MODDIR=$(ls -d /usr/lib/apache2/modules /usr/lib64/httpd/modules /usr/lib/httpd/modules 2>/dev/null | head -1)
[[ -n $APBIN && -n $MODDIR ]] || { echo "need apache2/httpd plus its module directory"; exit 3; }

. "$(dirname "$0")/env-db.sh"   # starts MariaDB, exports WSK_MYSQL / WSK_MYSQLDUMP, sets CLI MYSQLD DUMP

# ---- private Apache: our own ServerRoot, our own minimal module set, our own ports ----
A=$T/apache; mkdir -p "$A/conf.d" "$A/logs" "$A/run"
{
  echo "ServerRoot \"$A\""
  echo "PidFile \"$A/run/httpd.pid\""
  echo "ErrorLog \"$A/logs/error.log\""
  echo "LogLevel warn"
  echo "Mutex file:$A/run"
  if [[ $EUID -eq 0 ]]; then   # httpd refuses "User root" (unlike nginx); run workers as the distro's web user
    if id www-data >/dev/null 2>&1; then echo "User www-data"; echo "Group www-data"
    elif id apache >/dev/null 2>&1; then echo "User apache"; echo "Group apache"
    else echo "User daemon"; echo "Group daemon"; fi
  fi
  echo "TypesConfig /etc/mime.types"
  for m in mpm_event mpm_prefork; do [[ -e $MODDIR/mod_$m.so ]] && { echo "LoadModule ${m}_module $MODDIR/mod_$m.so"; break; }; done
  for m in unixd authz_core dir mime log_config alias rewrite ssl headers; do
    [[ -e $MODDIR/mod_$m.so ]] && echo "LoadModule ${m}_module $MODDIR/mod_$m.so"
  done
  echo "SSLSessionCache none"
  echo "IncludeOptional \"$A/conf.d/*.conf\""
} > "$A/httpd.conf"
printf '#!/bin/sh\nexec %s -d %s -f %s/httpd.conf "$@"\n' "$APBIN" "$A" "$A" > "$T/apache-wrap"; chmod +x "$T/apache-wrap"
chmod 711 "$T"   # mktemp dirs are 700; apache workers (www-data/apache) must traverse to the webroot
"$T/apache-wrap" -t || { echo "apache config test failed at startup"; cat "$A/logs/error.log" 2>/dev/null; exit 3; }

export WSK_SERVER=apache WSK_APACHE_CONFD="$A/conf.d" WSK_APACHE_T="$T/apache-wrap -t" \
       WSK_PREFIX="$T/root" WSK_ETC="$T/root/etc/wsk" WSK_WEBROOT_BASE="$T/root/www" \
       WSK_BACKUP_DIR="$T/root/backups" WSK_LOG_DIR="$A/logs" \
       WSK_CRON_FILE="$T/cron-wsk" WSK_LOGROTATE_FILE="$T/logrotate-wsk" WSK_HOSTNAME=web01
