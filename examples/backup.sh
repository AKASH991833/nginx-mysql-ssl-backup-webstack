#!/bin/sh
# One timestamped, checksummed backup of the shop database.
# Runs in the backup sidecar (at start and daily) and on demand: docker compose exec backup /backup.sh
set -eu
ts=$(date +%F_%H%M%S)
out="/backups/shop-$ts.sql.gz"
mariadb-dump -h db -u shop_app -p"$(cat /run/secrets/db_password)" --single-transaction --routines --triggers shop | gzip > "$out"
( cd /backups && sha256sum "$(basename "$out")" >> SHA256SUMS )
find /backups -name 'shop-*.sql.gz' -mtime +7 -delete
echo "backup written: $out"
