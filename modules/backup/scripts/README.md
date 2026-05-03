# Restore scripts

These ride along inside the restic repository under tag `scripts`. A
disaster-recovery operator with the passphrase + B2 credentials can
pull them back with:

```
restic -r s3:<endpoint>/<bucket> -p <passphrase> restore latest \
  --tag scripts --target /tmp/restore
ls /tmp/restore/scripts/
```

Each script wraps a `restic restore` invocation for a specific target
plus the post-restore steps (psql import, vault snapshot apply, kubectl
cp into a running pod, etc). Run after a fresh `./tf bootstrap-k3s` +
`./tf apply` brings the cluster back up empty.

| Script | Restores |
| --- | --- |
| `restore-postgres.sh <db> <snapshot-id>` | One Postgres database from `pg_dump` output |
| `restore-mysql.sh <db> <snapshot-id>` | One MySQL database from `mysqldump` output |
| `restore-redis.sh <snapshot-id>` | Redis RDB snapshot via `kubectl cp` + restart |
| `restore-vault.sh <snapshot-id>` | Vault raft state via `vault operator raft snapshot restore` |
| `restore-pv.sh <pv-name> <snapshot-id>` | One hostPath PV directory by name |
| `restore-config.sh <snapshot-id>` | Operator's gitignored `.env` + `config/` to local disk |

`<snapshot-id>` defaults to `latest` for each tag if omitted. Use
`restic snapshots --tag <tag>` to list what's available.

## Bootstrap order after total loss

1. Fresh cluster — `./tf bootstrap-k3s`
2. Pull operator config: `restore-config.sh latest`
3. `./tf apply` (with restored `.env` + `config/`)
4. Once Postgres/MySQL/Vault pods are Ready:
   - `restore-postgres.sh <db> latest` for each DB
   - `restore-mysql.sh <db> latest` for each DB
   - `restore-vault.sh latest`
5. Once mail/wordpress pods exist:
   - Stop pod (scale to 0), `restore-pv.sh <name> latest`, scale back up
6. Verify with smoke tests
