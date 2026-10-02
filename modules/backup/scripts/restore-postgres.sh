#!/usr/bin/env bash
# Restore Postgres from a restic snapshot.
#
# Usage:
#   restore-postgres.sh <db_name> [snapshot_id]          one database
#   CONFIRM=yes restore-postgres.sh --all [snapshot_id]  whole cluster
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
# The backup job writes either per-database `<db>.sql.gz` (pg_dump, when
# services.backup.postgres_databases is set) or one `all.sql.gz`
# (pg_dumpall). Both use `--clean --if-exists`.
#
# One database, other databases and roles untouched:
#   - from `<db>.sql.gz` (pg_dump --clean): created if missing, objects
#     replaced in place;
#   - from the `-- Database "<db>" dump` section of `all.sql.gz`: that
#     section recreates the database (its own CREATE DATABASE keeps owner,
#     encoding and locale) and has no per-object DROPs, so an existing
#     database is dropped first — CONFIRM=yes required, connections are
#     terminated.
# The roles the dump refers to must exist (restore with --all, or
# recreate them, if the cluster is new).
#
# Whole cluster (--all): replays `all.sql.gz`, which drops and recreates
# every database and role in it. Stop the consumers first — open
# connections make DROP DATABASE fail.
set -euo pipefail

TARGET="${1:?usage: restore-postgres.sh <db_name>|--all [snapshot_id]}"
SNAP="${2:-latest}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

restore_from_snapshot() {
  echo "[postgres] restic restore $SNAP --tag postgres"
  restic restore "$SNAP" --tag postgres --target "$STAGE" "$@"
}

if [ "$TARGET" = "--all" ]; then
  if [ "${CONFIRM:-}" != "yes" ]; then
    echo "[postgres] refusing: --all drops and recreates every database; set CONFIRM=yes" >&2
    exit 2
  fi
  restore_from_snapshot --include "*/all.sql.gz"
  DUMP=$(find "$STAGE" -name all.sql.gz | head -1)
  if [ -z "$DUMP" ]; then
    echo "[postgres] no all.sql.gz in snapshot $SNAP" >&2
    exit 2
  fi
  # `--clean` dumps start with DROP/CREATE ROLE for every role, including
  # the one this session is connected as, which Postgres refuses to drop.
  # Skip just those two statements; anything else still stops the replay.
  ME=$(psql -At -d postgres -c 'SELECT current_user')
  echo "[postgres] replaying the whole cluster dump"
  gunzip -c "$DUMP" | awk -v me="$ME" '
    $0 == "DROP ROLE IF EXISTS " me ";" { next }
    $0 == "CREATE ROLE " me ";" { next }
    { print }
  ' | psql --set ON_ERROR_STOP=1 -d postgres
  echo "[postgres] cluster restored from $SNAP"
  exit 0
fi

DB="$TARGET"
restore_from_snapshot --include "*/$DB.sql.gz" --include "*/all.sql.gz"

# psql interpolates :'var' / :"var" only in script input, not in -c.
ensure_db() {
  if [ -z "$(echo "SELECT 1 FROM pg_database WHERE datname = :'db'" | psql -At -d postgres -v db="$DB")" ]; then
    echo "[postgres] creating database $DB"
    echo 'CREATE DATABASE :"db"' | psql --set ON_ERROR_STOP=1 -d postgres -v db="$DB"
  fi
}

DUMP=$(find "$STAGE" -name "$DB.sql.gz" | head -1)
if [ -n "$DUMP" ]; then
  ensure_db
  echo "[postgres] restoring $DB from $DB.sql.gz"
  gunzip -c "$DUMP" | psql --set ON_ERROR_STOP=1 -d "$DB"
else
  DUMP=$(find "$STAGE" -name all.sql.gz | head -1)
  if [ -z "$DUMP" ]; then
    echo "[postgres] no $DB.sql.gz or all.sql.gz in snapshot $SNAP" >&2
    exit 2
  fi
  # The section starts at `-- Database "<db>" dump` and ends at the next
  # `-- PostgreSQL database dump complete`; it carries its own
  # CREATE DATABASE and `\connect`.
  gunzip -c "$DUMP" | awk -v db="$DB" '
    $0 == "-- Database \"" db "\" dump" { on = 1; found = 1 }
    on { print }
    on && $0 == "-- PostgreSQL database dump complete" { on = 0 }
    END { if (!found) exit 3 }
  ' >"$STAGE/$DB.sql" || {
    echo "[postgres] database $DB not found in all.sql.gz" >&2
    exit 2
  }
  if [ -n "$(echo "SELECT 1 FROM pg_database WHERE datname = :'db'" | psql -At -d postgres -v db="$DB")" ]; then
    if [ "${CONFIRM:-}" != "yes" ]; then
      echo "[postgres] refusing: $DB exists and the all.sql.gz section recreates it; set CONFIRM=yes to drop it first" >&2
      exit 2
    fi
    echo "[postgres] dropping existing $DB"
    echo 'DROP DATABASE :"db" WITH (FORCE)' | psql --set ON_ERROR_STOP=1 -d postgres -v db="$DB"
  fi
  echo "[postgres] restoring $DB from its all.sql.gz section"
  psql --set ON_ERROR_STOP=1 -d postgres -f "$STAGE/$DB.sql"
fi

echo "[postgres] restored $DB from $SNAP"
