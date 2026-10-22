# shellcheck shell=bash
# Starts a private nginx + MariaDB as the current user and exports the WSK_* variables. Sourced by tests/run.sh and docs/demo.sh
T=$(mktemp -d); WSK=$PWD/wsk
cleanup() { [[ -f $T/nginx/nginx.pid ]] && kill "$(cat "$T/nginx/nginx.pid")" 2>/dev/null; [[ -f $T/mysqld.pid ]] && kill "$(cat "$T/mysqld.pid")" 2>/dev/null; sleep 1; rm -rf "$T"; }
trap cleanup EXIT

NGINX=$(command -v nginx || ls /usr/sbin/nginx 2>/dev/null)
MYSQLD=$(command -v mariadbd || command -v mysqld || ls /usr/sbin/mariadbd /usr/sbin/mysqld /usr/libexec/mariadbd /usr/libexec/mysqld 2>/dev/null | head -1)
CLI=$(command -v mariadb || command -v mysql)
[[ $EUID -eq 0 ]] && MYSQLD="$MYSQLD --user=root"   # containers/CI run as root; mysqld refuses to run as root without this
DUMP=$(command -v mariadb-dump || command -v mysqldump)
INSTALL_DB=$(command -v mariadb-install-db || command -v mysql_install_db || true)
[[ -n $NGINX && -n $MYSQLD && -n $CLI ]] || { echo "need nginx + mariadbd + client on PATH"; exit 3; }

# ---- start MariaDB as the current user ----
BASEDIR_ARG=""; [[ -n ${WSK_TEST_BASEDIR:-} ]] && BASEDIR_ARG="--basedir=$WSK_TEST_BASEDIR"   # only needed for a non-system install
$INSTALL_DB --no-defaults --datadir="$T/data" $BASEDIR_ARG --auth-root-authentication-method=normal --skip-test-db >"$T/install.log" 2>&1
( $MYSQLD --no-defaults --datadir="$T/data" $BASEDIR_ARG --socket="$T/s.sock" --pid-file="$T/mysqld.pid" --port=0 --skip-networking >"$T/mysqld.log" 2>&1 & )
for _ in $(seq 1 40); do $CLI -S "$T/s.sock" -uroot -e 'select 1' >/dev/null 2>&1 && break; sleep 0.5; done
$CLI -S "$T/s.sock" -uroot -e 'select 1' >/dev/null 2>&1 || { echo "MariaDB did not start"; echo "--- mysqld.log:"; tail -15 "$T/mysqld.log"; echo "--- install.log:"; tail -15 "$T/install.log"; echo "MYSQLD=$MYSQLD INSTALL_DB=$INSTALL_DB"; exit 3; }

# ---- nginx wrapper using a private prefix ----
mkdir -p "$T/nginx/conf.d" "$T/nginx/logs" "$T/log"
cat > "$T/nginx/nginx.conf" <<C
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
       WSK_MYSQL="$CLI -S $T/s.sock -uroot" WSK_MYSQLDUMP="$DUMP -S $T/s.sock -uroot" WSK_CRON_FILE="$T/cron-wsk" WSK_LOGROTATE_FILE="$T/logrotate-wsk" WSK_HOSTNAME=web01
