#!/usr/bin/env bash
# Restore Redis/Valkey keys from a restic snapshot.
#
# Usage: CONFIRM=yes restore-redis.sh [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   REDIS_NS          — namespace of the Redis Service (default: platform)
#   REDIS_TARGET_HOST — host the keys go to (default: redis.<ns>.svc.cluster.local;
#                       in Sentinel mode that Service fronts the current primary)
#   REDIS_SECRET      — Secret with the default-user password (default: redis-default)
#   REDIS_SECRET_KEY  — key inside it (default: REDIS_PASSWORD)
#   RESTORE_IMAGE     — image for the temporary server (default: valkey/valkey:9-alpine)
#   CONFIRM=yes       — required; keys in the snapshot overwrite live keys
#
# Works for the single-instance and the Sentinel topology alike: the RDB is
# loaded into a temporary server in a throw-away pod, and every key is
# copied to the live primary with `MIGRATE ... COPY REPLACE` (TTLs kept).
# It is a merge: keys that exist live but not in the snapshot stay (FLUSH*
# is disabled on the platform's Valkey). The platform runs Redis as a
# cache, so this is rarely needed — consumers rebuild their entries.
set -euo pipefail

SNAP="${1:-latest}"
NS="${REDIS_NS:-platform}"
TARGET="${REDIS_TARGET_HOST:-redis.$NS.svc.cluster.local}"
SECRET="${REDIS_SECRET:-redis-default}"
SECRET_KEY="${REDIS_SECRET_KEY:-REDIS_PASSWORD}"
IMAGE="${RESTORE_IMAGE:-valkey/valkey:9-alpine}"
POD="redis-restore-$(date +%s)"

if [ "${CONFIRM:-}" != "yes" ]; then
  echo "[redis] refusing: keys from the snapshot overwrite live keys on $TARGET; set CONFIRM=yes" >&2
  exit 2
fi

STAGE=$(mktemp -d)
cleanup() {
  kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "[redis] restic restore $SNAP --tag redis"
restic restore "$SNAP" --tag redis --target "$STAGE"
RDB=$(find "$STAGE" -name dump.rdb | head -1)
if [ -z "$RDB" ]; then
  echo "[redis] no dump.rdb in snapshot $SNAP" >&2
  exit 2
fi

echo "[redis] starting temporary server pod $NS/$POD"
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels: { app.kubernetes.io/component: redis-restore }
spec:
  restartPolicy: Never
  containers:
    - name: valkey
      image: $IMAGE
      command: ["sh", "-c", "until [ -f /data/ready ]; do sleep 1; done; exec valkey-server --dir /data --dbfilename dump.rdb --appendonly no --save '' --port 6379"]
      env:
        - name: TARGET_PASSWORD
          valueFrom: { secretKeyRef: { name: $SECRET, key: $SECRET_KEY } }
      resources:
        requests: { cpu: 100m, memory: 256Mi }
        limits: { cpu: "1", memory: 1Gi }
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes: [{ name: data, emptyDir: {} }]
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null
kubectl -n "$NS" cp "$RDB" "$POD:/data/dump.rdb" -c valkey
kubectl -n "$NS" exec "$POD" -c valkey -- touch /data/ready
kubectl -n "$NS" exec "$POD" -c valkey -- sh -c 'until valkey-cli ping 2>/dev/null | grep -q PONG; do sleep 1; done'

COUNT=$(kubectl -n "$NS" exec "$POD" -c valkey -- valkey-cli dbsize)
echo "[redis] snapshot holds $COUNT keys; migrating to $TARGET"
# MIGRATE answers NOKEY when a batch had nothing left to move — not an error.
kubectl -n "$NS" exec "$POD" -c valkey -- sh -ec "
  valkey-cli --scan --count 1000 | tr '\\n' '\\0' |
    xargs -0 -r -n 100 sh -c 'out=\$(valkey-cli --no-auth-warning MIGRATE \"$TARGET\" 6379 \"\" 0 10000 COPY REPLACE AUTH2 default \"\$TARGET_PASSWORD\" KEYS \"\$@\"); case \"\$out\" in OK|NOKEY) ;; *) echo \"\$out\" >&2; exit 255 ;; esac' _
"

echo "[redis] restored $COUNT keys from $SNAP into $TARGET"
