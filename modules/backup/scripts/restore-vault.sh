#!/usr/bin/env bash
# Restore Vault raft state from a restic snapshot.
#
# Usage: restore-vault.sh [snapshot_id]
#
# Env:
#   RESTIC_REPOSITORY / RESTIC_PASSWORD / AWS_ACCESS_KEY_ID /
#   AWS_SECRET_ACCESS_KEY — restic + B2 creds
#   VAULT_ADDR  — public Vault URL (https://secrets.<domain>)
#   VAULT_TOKEN — root token
#
# The destination Vault must be initialised + unsealed. After
# `vault operator raft snapshot restore`, the recovered raft state
# REPLACES whatever the running Vault had — every secret + auth
# method + policy + token reverts to the snapshot point. That
# usually means re-pasting the root token from the password
# manager or the bootstrap Secret.
set -euo pipefail

SNAP="${1:-latest}"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "[vault] restic restore $SNAP --tag vault"
restic restore "$SNAP" --tag vault --target "$STAGE"
SNAP_FILE=$(find "$STAGE" -name vault.snap | head -1)
if [ -z "$SNAP_FILE" ]; then
  echo "[vault] no vault.snap in snapshot $SNAP" >&2
  exit 2
fi

echo "[vault] operator raft snapshot restore (force)"
vault operator raft snapshot restore -force "$SNAP_FILE"

echo "[vault] restored from $SNAP — re-paste root token if it changed"
