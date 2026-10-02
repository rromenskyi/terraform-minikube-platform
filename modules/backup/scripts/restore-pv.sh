#!/usr/bin/env bash
# Restore one hostPath PV directory from a restic snapshot.
#
# Usage: CONFIRM=yes restore-pv.sh <pv_name> [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   PV_TARGET_PATH        — host directory to restore into
#                           (e.g. /data/vol/platform/stalwart/data)
#   PV_BASE               — directory every target must sit under
#                           (default /data/vol, the host_volume_path)
#   CONFIRM=yes           — required; the target's content is replaced
#
# Run on the node that holds the volume, with the consuming workload
# scaled to 0 — restoring under a running Stalwart / WordPress / etc
# corrupts the new state:
#
#   kubectl -n <ns> scale deploy/<workload> --replicas=0
#   CONFIRM=yes restore-pv.sh <name> <snapshot>
#   kubectl -n <ns> scale deploy/<workload> --replicas=1
#
# Nothing is deleted. The archive is verified and extracted next to the
# target first; then the current content moves aside to
# `<target>.pre-restore-<timestamp>` and the extracted tree takes its
# place. Remove the old copy once the workload runs fine.
set -euo pipefail

NAME="${1:?usage: CONFIRM=yes restore-pv.sh <pv_name> [snapshot_id]}"
SNAP="${2:-latest}"
TARGET_IN="${PV_TARGET_PATH:?PV_TARGET_PATH must be set to the host directory}"
BASE_IN="${PV_BASE:-/data/vol}"

if [ "${CONFIRM:-}" != "yes" ]; then
  echo "[pv] refusing: set CONFIRM=yes to replace the content of $TARGET_IN" >&2
  exit 2
fi
if [ -L "$TARGET_IN" ]; then
  echo "[pv] refusing: $TARGET_IN is a symlink" >&2
  exit 2
fi

BASE=$(realpath -e "$BASE_IN")
TARGET=$(realpath -m "$TARGET_IN")
case "$TARGET" in
  "$BASE"/?*) ;;
  *)
    echo "[pv] refusing: $TARGET is not below $BASE" >&2
    exit 2
    ;;
esac

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Each node's backup job writes its own snapshots, so "latest" alone may
# not contain this archive: pick the newest snapshot that does.
if [ "$SNAP" = "latest" ]; then
  SNAP=""
  for id in $(restic snapshots --no-lock --tag pv --json | grep -o '"short_id":"[^"]*"' | cut -d'"' -f4 | tac); do
    if restic ls --no-lock "$id" | grep -q "/$NAME.tar.gz$"; then SNAP="$id"; break; fi
  done
  if [ -z "$SNAP" ]; then
    echo "[pv] no snapshot with $NAME.tar.gz" >&2
    exit 2
  fi
fi

echo "[pv] restic restore $SNAP --tag pv"
restic restore "$SNAP" --tag pv --target "$STAGE" \
  --include "*/$NAME.tar.gz"

TARBALL=$(find "$STAGE" -name "$NAME.tar.gz" | head -1)
if [ -z "$TARBALL" ]; then
  echo "[pv] no $NAME.tar.gz in snapshot $SNAP" >&2
  exit 2
fi

echo "[pv] verifying archive"
tar -tzf "$TARBALL" >/dev/null

STAMP=$(date +%Y%m%d%H%M%S)
NEW="$TARGET.restore-$STAMP"
OLD="$TARGET.pre-restore-$STAMP"
mkdir -p "$NEW"
echo "[pv] extracting into $NEW"
tar -xzf "$TARBALL" -C "$NEW"

if [ -e "$TARGET" ]; then
  # Keep the mount point's own owner/mode for the restored tree.
  chown --reference="$TARGET" "$NEW" 2>/dev/null || true
  chmod --reference="$TARGET" "$NEW" 2>/dev/null || true
  mv "$TARGET" "$OLD"
  echo "[pv] previous content kept at $OLD"
fi
mv "$NEW" "$TARGET"

echo "[pv] restored $NAME into $TARGET"
