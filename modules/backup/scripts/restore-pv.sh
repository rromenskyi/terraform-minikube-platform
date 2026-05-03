#!/usr/bin/env bash
# Restore one hostPath PV directory from a restic snapshot.
#
# Usage: restore-pv.sh <pv_name> [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   PV_TARGET_PATH        — absolute host directory to extract into
#                           (e.g. /data/vol/platform/stalwart/data)
#
# The host path MUST already exist (TF re-creates it on apply via
# the matching `kubernetes_persistent_volume_v1.<name>` resource).
# This script ASSUMES the consuming pod is scaled to 0 — running
# Stalwart / WordPress / etc on top of an in-progress untar will
# corrupt the new state. Operator should:
#
#   kubectl -n <ns> scale deploy/<workload> --replicas=0
#   restore-pv.sh <name> <snapshot>
#   kubectl -n <ns> scale deploy/<workload> --replicas=1
set -euo pipefail

NAME="${1:?usage: restore-pv.sh <pv_name> [snapshot_id]}"
SNAP="${2:-latest}"
TARGET="${PV_TARGET_PATH:?PV_TARGET_PATH must be set to the host directory}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[pv] restic restore $SNAP --tag pv"
restic restore "$SNAP" --tag pv --target "$STAGE" \
  --include "*/$NAME.tar.gz"

TARBALL=$(find "$STAGE" -name "$NAME.tar.gz" | head -1)
if [ -z "$TARBALL" ]; then
  echo "[pv] no $NAME.tar.gz in snapshot $SNAP" >&2
  exit 2
fi

echo "[pv] wiping $TARGET and untarring"
rm -rf "$TARGET"/*
tar -xzf "$TARBALL" -C "$TARGET"

echo "[pv] restored $NAME into $TARGET"
