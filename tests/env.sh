# shellcheck shell=bash
# Starts a private nginx + MariaDB as the current user and exports the WSK_* variables. Sourced by tests/run.sh and docs/demo.sh
T=$(mktemp -d); WSK=$PWD/wsk
cleanup() { [[ -f $T/nginx/nginx.pid ]] && kill "$(cat "$T/nginx/nginx.pid")" 2>/dev/null; [[ -f $T/mysqld.pid ]] && kill "$(cat "$T/mysqld.pid")" 2>/dev/null; sleep 1; rm -rf "$T"; }
trap cleanup EXIT

NGINX=$(command -v nginx || ls /usr/sbin/nginx 2>/dev/null)
[[ -n $NGINX ]] || { echo "need nginx on PATH"; exit 3; }
USER_ARG=""; [[ $EUID -eq 0 ]] && USER_ARG="--user=root"   # containers/CI run as root; mysqld refuses to run as root without this

. "$(dirname "$0")/env-db.sh"   # starts MariaDB, exports WSK_MYSQL / WSK_MYSQLDUMP, sets CLI MYSQLD DUMP

# ---- nginx wrapper using a private prefix ----
mkdir -p "$T/nginx/conf.d" "$T/nginx/logs" "$T/log"
cat > "$T/nginx/nginx.conf" <<C
$( [[ $EUID -eq 0 ]] && echo "user root;" )
worker_processes 1; pid $T/nginx/nginx.pid; error_log $T/nginx/logs/error.log;
events { worker_connections 64; }
http {
  types { text/html html; text/css css; }
  client_body_temp_path $T/nginx/tmp1; proxy_temp_path $T/nginx/tmp2; fastcgi_temp_path $T/nginx/tmp3; uwsgi_temp_path $T/nginx/tmp4; scgi_temp_path $T/nginx/tmp5;
  access_log off;
  include $T/nginx/conf.d/*.conf;
}
C
printf '#!/bin/sh\nexec %s -p %s/nginx/ -c %s/nginx/nginx.conf "$@"\n' "$NGINX" "$T" "$T" > "$T/nginx-wrap"; chmod +x "$T/nginx-wrap"

export WSK_PREFIX="$T/root" WSK_ETC="$T/root/etc/wsk" WSK_NGINX_CONFD="$T/nginx/conf.d" WSK_WEBROOT_BASE="$T/root/www" \
       WSK_BACKUP_DIR="$T/root/backups" WSK_LOG_DIR="$T/log" WSK_NGINX_BIN="$T/nginx-wrap" \
       WSK_CRON_FILE="$T/cron-wsk" WSK_LOGROTATE_FILE="$T/logrotate-wsk" WSK_HOSTNAME=web01
