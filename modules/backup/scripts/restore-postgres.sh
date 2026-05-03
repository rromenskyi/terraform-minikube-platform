#!/usr/bin/env bash
# Restore one Postgres database from a restic snapshot.
#
# Usage: restore-postgres.sh <db_name> [snapshot_id]
#
# Env (set on caller side, NOT hardcoded):
#   RESTIC_REPOSITORY     — s3:<endpoint>/<bucket>
#   RESTIC_PASSWORD       — repo passphrase
#   AWS_ACCESS_KEY_ID     — B2 key id
#   AWS_SECRET_ACCESS_KEY — B2 key secret
#   PGHOST                — in-cluster Postgres host (e.g. via kubectl port-forward)
#   PGUSER                — postgres
#   PGPASSWORD            — superuser password
#
# Flow:
#   1. Pull the named DB's `.sql.gz` from the latest (or named)
#      `tag=postgres` snapshot.
#   2. `psql --set ON_ERROR_STOP=1` the dump back. The dump uses
#      `--clean --if-exists`, so it's safe to run against a DB
#      that already has the schema.
set -euo pipefail

DB="${1:?usage: restore-postgres.sh <db_name> [snapshot_id]}"
SNAP="${2:-latest}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[postgres] restic restore $SNAP --tag postgres"
restic restore "$SNAP" --tag postgres --target "$STAGE" \
  --include "*/$DB.sql.gz"

DUMP=$(find "$STAGE" -name "$DB.sql.gz" | head -1)
if [ -z "$DUMP" ]; then
  echo "[postgres] no dump found for db=$DB in snapshot $SNAP" >&2
  exit 2
fi

echo "[postgres] piping dump into psql"
gunzip -c "$DUMP" | psql --set ON_ERROR_STOP=1 -d postgres

echo "[postgres] restored $DB from $SNAP"
