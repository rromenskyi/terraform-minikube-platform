#!/usr/bin/env bash
# Restore one MySQL database from a restic snapshot.
#
# Usage: restore-mysql.sh <db_name> [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   MYSQL_HOST            — in-cluster MySQL host
#   MYSQL_PWD             — root password (env name `mysql` reads)
set -euo pipefail

DB="${1:?usage: restore-mysql.sh <db_name> [snapshot_id]}"
SNAP="${2:-latest}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[mysql] restic restore $SNAP --tag mysql"
restic restore "$SNAP" --tag mysql --target "$STAGE" \
  --include "*/$DB.sql.gz"

DUMP=$(find "$STAGE" -name "$DB.sql.gz" | head -1)
if [ -z "$DUMP" ]; then
  echo "[mysql] no dump found for db=$DB in snapshot $SNAP" >&2
  exit 2
fi

echo "[mysql] piping dump into mysql"
gunzip -c "$DUMP" | mysql -h "$MYSQL_HOST" -u root "$DB"

echo "[mysql] restored $DB from $SNAP"
