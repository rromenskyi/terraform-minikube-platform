#!/usr/bin/env bash
# Restore the operator's gitignored configuration to the local
# disk after a clone-from-scratch / disaster recovery.
#
# Usage: restore-config.sh [snapshot_id] [target_dir]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#
# Pulls every file uploaded under `tag=operator-config` (i.e.
# `.env`, `config/platform.yaml`, `config/domains/*.yaml`,
# anything else the operator chose to capture via
# `./tf backup-config`). Default target is the current working
# directory; pass `~/platform` (or wherever) explicitly to land
# the files in the right repo clone.
set -euo pipefail

SNAP="${1:-latest}"
TARGET="${2:-.}"

echo "[config] restic restore $SNAP --tag operator-config -> $TARGET"
restic restore "$SNAP" --tag operator-config --target "$TARGET"

echo "[config] done — review files in $TARGET before running ./tf apply"
