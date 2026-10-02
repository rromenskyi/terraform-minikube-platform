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
#
# Works with both dump layouts the backup job writes: a per-database
# `<db>.sql.gz` (services.backup.mysql_databases set) or one
# `all.sql.gz` (--all-databases, the default). From the combined dump
# only the session header and the `-- Current Database: <db>` section
# are replayed, so other databases and the `mysql` system schema are
# left alone. (`mysql --one-database` is not enough: it still runs the
# other databases' CREATE DATABASE and aborts on their USE.)
set -euo pipefail

DB="${1:?usage: restore-mysql.sh <db_name> [snapshot_id]}"
SNAP="${2:-latest}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[mysql] restic restore $SNAP --tag mysql"
restic restore "$SNAP" --tag mysql --target "$STAGE" \
  --include "*/$DB.sql.gz" --include "*/all.sql.gz"

DUMP=$(find "$STAGE" -name "$DB.sql.gz" | head -1)
if [ -z "$DUMP" ]; then
  DUMP=$(find "$STAGE" -name "all.sql.gz" | head -1)
fi
if [ -z "$DUMP" ]; then
  echo "[mysql] no $DB.sql.gz or all.sql.gz in snapshot $SNAP" >&2
  exit 2
fi

echo "[mysql] restoring $DB from $(basename "$DUMP")"
if [ "$(basename "$DUMP")" = "all.sql.gz" ]; then
  gunzip -c "$DUMP" | awk -v db="$DB" '
    /^-- Current Database: `/ { seen = 1; cur = ($0 == "-- Current Database: `" db "`") ; if (cur) found = 1 }
    !seen || cur { print }
    END { if (!found) exit 3 }
  ' >"$STAGE/$DB.sql" || {
    echo "[mysql] database $DB not found in all.sql.gz" >&2
    exit 2
  }
  mysql -h "$MYSQL_HOST" -u root <"$STAGE/$DB.sql"
else
  mysql -h "$MYSQL_HOST" -u root -e "CREATE DATABASE IF NOT EXISTS \`$DB\`"
  gunzip -c "$DUMP" | mysql -h "$MYSQL_HOST" -u root "$DB"
fi

echo "[mysql] restored $DB from $SNAP"
