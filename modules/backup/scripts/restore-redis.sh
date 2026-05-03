#!/usr/bin/env bash
# Restore Redis state from a restic snapshot.
#
# Usage: restore-redis.sh [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   REDIS_NS    — namespace where the redis StatefulSet lives (default: platform)
#   REDIS_POD   — pod name (default: redis-0)
#
# Redis loads its RDB at startup. The flow is:
#   1. Pull `dump.rdb` from the snapshot.
#   2. `kubectl cp` the file into the redis pod's data dir,
#      replacing whatever is there.
#   3. `kubectl rollout restart` the StatefulSet so redis re-reads
#      the RDB on next boot.
#
# That implies the operator is OK with whatever in-memory state
# the running redis has (sessions, BullMQ queues, …) being
# overwritten by the RDB content.
set -euo pipefail

SNAP="${1:-latest}"
NS="${REDIS_NS:-platform}"
POD="${REDIS_POD:-redis-0}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[redis] restic restore $SNAP --tag redis"
restic restore "$SNAP" --tag redis --target "$STAGE"
RDB=$(find "$STAGE" -name dump.rdb | head -1)
if [ -z "$RDB" ]; then
  echo "[redis] no dump.rdb in snapshot $SNAP" >&2
  exit 2
fi

echo "[redis] kubectl cp -> $NS/$POD:/data/dump.rdb"
kubectl -n "$NS" cp "$RDB" "$POD:/data/dump.rdb"

echo "[redis] kubectl rollout restart sts/redis"
kubectl -n "$NS" rollout restart sts/redis
kubectl -n "$NS" rollout status sts/redis --timeout=180s

echo "[redis] restored from $SNAP"
