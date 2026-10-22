# shellcheck shell=bash
# Starts a private MariaDB as the current user. Shared by env.sh (nginx suite) and env-apache.sh (apache suite).
# Expects: $T (a scratch dir the caller owns). Exports: WSK_MYSQL, WSK_MYSQLDUMP. Sets: MYSQLD CLI DUMP.
MYSQLD=$(command -v mariadbd || command -v mysqld || ls /usr/sbin/mariadbd /usr/sbin/mysqld /usr/libexec/mariadbd /usr/libexec/mysqld 2>/dev/null | head -1)
CLI=$(command -v mariadb || command -v mysql)
DUMP=$(command -v mariadb-dump || command -v mysqldump)
INSTALL_DB=$(command -v mariadb-install-db || command -v mysql_install_db || true)
[[ -n $MYSQLD && -n $CLI ]] || { echo "need mariadbd + client on PATH"; exit 3; }

# ---- start MariaDB as the current user ----
BASEDIR_ARG=""; [[ -n ${WSK_TEST_BASEDIR:-} ]] && BASEDIR_ARG="--basedir=$WSK_TEST_BASEDIR"   # only needed for a non-system install
$INSTALL_DB --no-defaults --datadir="$T/data" $BASEDIR_ARG --auth-root-authentication-method=normal --skip-test-db >"$T/install.log" 2>&1
( $MYSQLD --no-defaults $USER_ARG --datadir="$T/data" $BASEDIR_ARG --socket="$T/s.sock" --pid-file="$T/mysqld.pid" --port=0 --skip-networking --log-error="$T/mysqld.errlog" >"$T/mysqld.log" 2>&1 & )
for _ in $(seq 1 120); do $CLI -S "$T/s.sock" -uroot -e 'select 1' >/dev/null 2>&1 && break; sleep 0.5; done
$CLI -S "$T/s.sock" -uroot -e 'select 1' >/dev/null 2>&1 || { echo "MariaDB did not start"; echo "--- mysqld.log:"; tail -15 "$T/mysqld.log"; echo "--- mysqld.errlog:"; tail -15 "$T/mysqld.errlog" 2>/dev/null; echo "--- install.log:"; tail -15 "$T/install.log"; echo "MYSQLD=$MYSQLD INSTALL_DB=$INSTALL_DB"; ps aux | grep -i maria | grep -v grep; exit 3; }
export WSK_MYSQL="$CLI -S $T/s.sock -uroot" WSK_MYSQLDUMP="$DUMP -S $T/s.sock -uroot"
