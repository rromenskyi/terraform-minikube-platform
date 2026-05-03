# Platform backups — operator manual

Backups + restore for the platform's stateful tier. One restic
repository on a dedicated B2 bucket carries every backup target;
encryption is built in (AES-256 + Poly1305 with a passphrase).
This document is the canonical operator guide; it ships in the
restic repo under tag `scripts` so disaster-recovery operators
can `restic restore` it back even after losing the local repo
clone.

## What gets backed up and when

Default schedules in UTC. Tweak via `services.backup.schedule_*`
in `config/platform.yaml`. Each CronJob runs in the `backups`
namespace and pushes to one shared restic repo, with a
distinguishing `--tag` and `--host`.

| Target          | Default cron         | Tag               | Source                                          |
| ---             | ---                  | ---               | ---                                             |
| Postgres dumps  | `0 3 * * *`  daily   | `postgres`        | per-DB `pg_dump` (or `pg_dumpall` if list empty) |
| MySQL dumps     | `15 3 * * *` daily   | `mysql`           | per-DB `mariadb-dump` (or `--all-databases`)     |
| Redis snapshot  | `30 3 * * *` daily   | `redis`           | `redis-cli --rdb`                                |
| Vault raft      | `45 3 * * *` daily   | `vault`           | `vault operator raft snapshot save`              |
| hostPath PVs    | `0 4 * * 0`  weekly  | `pv`              | `tar -czf` per `services.backup.pv_paths` entry  |
| Retention prune | `0 5 * * 0`  weekly  | —                 | `restic forget --prune`                          |
| Operator config | `0 2 * * *`  daily   | `operator-config` | `./tf backup-config` from operator's machine     |
| Restore scripts | one-shot, on apply   | `scripts`         | this directory                                   |

Retention defaults: `--keep-daily 7 --keep-weekly 4
--keep-monthly 6` per (host, tag). The prune CronJob applies it
weekly.

## Initial setup

1. Create a B2 bucket dedicated to backups. **Must be a different
   bucket from the one the Terraform S3 backend uses for
   tfstate** — a tfstate-key compromise must not delete or
   overwrite encrypted backups.
2. Create a B2 application key scoped to that single bucket. The
   key needs `listBuckets`, `listFiles`, `readFiles`,
   `writeFiles` at minimum. Skip `deleteFiles` if you want
   write-once immutability — but then `restic forget --prune`
   won't be able to expire old snapshots and the bucket grows
   forever.
3. Add to the operator's gitignored `.env`:

       TF_VAR_backup_b2_bucket=<bucket-name>
       TF_VAR_backup_b2_endpoint=https://s3.<region>.backblazeb2.com
       TF_VAR_backup_b2_access_key_id=<key-id>
       TF_VAR_backup_b2_secret_access_key=<key-secret>

4. Flip on in `config/platform.yaml`:

       services:
         backup:
           enabled: true
           postgres_databases: [<db1>, <db2>, ...]
           mysql_databases: []                  # empty = all
           pv_paths:
             - { name: <stable-id>, path: <absolute-host-path> }
           pv_node_selector:
             <key>: <value>                     # for hostPath PV node-pinning

5. `./tf apply` — creates the namespace, restic init Job (uploads
   restore scripts as `tag=scripts`), 6 CronJobs (5 backup + 1
   prune).

6. **Stash the passphrase in a password manager:**

       ./tf output -raw backup_passphrase

   Losing it bricks every encrypted snapshot forever; restic
   AES-256 has no recovery path.

7. Install `restic` locally so the operator-side
   `./tf backup-config` works (uses your distro's package
   manager, no special build needed).

8. Add a host-side cron entry to capture operator config nightly.
   Absolute path matters when cron runs without an interactive
   shell:

       0 2 * * * /home/<user>/platform/tf backup-config >> \
         /home/<user>/platform/.backup-config.log 2>&1

## Health checks

| Want to know                   | Command                                                                                       |
| ---                            | ---                                                                                           |
| Is each CronJob succeeding?    | `kubectl -n backups get jobs --sort-by=.metadata.creationTimestamp | tail -10`               |
| Last successful run per target | `kubectl -n backups get cronjobs`                                                              |
| Any in-flight failure logs     | `kubectl -n backups logs -l app.kubernetes.io/component=backup-postgres --tail=30`            |
| List snapshots in restic       | `RESTIC_REPOSITORY=$(./tf output -raw backup_repository_url \| tail -1) restic snapshots`     |
| Total bytes stored             | `restic stats --mode raw-data`                                                                 |

The wrapper writes `Loading variables…` to stdout, so `./tf
output -raw …` needs `| tail -1` when piping into another tool.

## Manual one-shot run (skip the schedule)

Trigger any CronJob immediately by spawning a one-off Job:

    kubectl -n backups create job manual-postgres --from=cronjob/backup-postgres
    kubectl -n backups logs -l job-name=manual-postgres -f

Same shape for `backup-mysql` / `backup-redis` / `backup-vault` /
`backup-pv` / `backup-prune`. Useful to verify a config change
without waiting until next scheduled fire.

## Restoring from a snapshot

Every restore script reads `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` from the environment.
Set them once at the top of the operator's session:

    export RESTIC_REPOSITORY=$(./tf output -raw backup_repository_url | tail -1)
    export RESTIC_PASSWORD=$(./tf output -raw backup_passphrase | tail -1)
    source .env
    export AWS_ACCESS_KEY_ID=$TF_VAR_backup_b2_access_key_id
    export AWS_SECRET_ACCESS_KEY=$TF_VAR_backup_b2_secret_access_key

| Script                                  | Restores                                                  |
| ---                                     | ---                                                       |
| `restore-postgres.sh <db> [snapshot]`   | One Postgres database from `pg_dump` output              |
| `restore-mysql.sh <db> [snapshot]`      | One MySQL database from `mariadb-dump` output            |
| `restore-redis.sh [snapshot]`           | Redis RDB via `kubectl cp` + `rollout restart sts/redis` |
| `restore-vault.sh [snapshot]`           | Vault raft via `vault operator raft snapshot restore`    |
| `restore-pv.sh <name> [snapshot]`       | One hostPath PV directory by name                        |
| `restore-config.sh [snapshot] [target]` | Operator's `.env` + `config/` to local disk              |

`<snapshot>` defaults to `latest` for each tag. `restic snapshots
--tag <tag>` lists what's available; `restic snapshots --tag <tag>
--latest 1` shows just the most recent.

For `restore-pv.sh`, scale the consuming workload to 0 first to
avoid corruption from a live untar:

    kubectl -n <ns> scale deploy/<workload> --replicas=0
    PV_TARGET_PATH=<absolute-host-path> restore-pv.sh <name> latest
    kubectl -n <ns> scale deploy/<workload> --replicas=1

## Sanity-check a snapshot without touching anything live

Restore to a tmp dir, inspect, throw away. Never imports
anything; the live cluster never sees the restored bytes.

    mkdir -p /tmp/r
    for tag in postgres mysql redis vault pv operator-config; do
      rm -rf /tmp/r/$tag; mkdir -p /tmp/r/$tag
      restic restore latest --tag $tag --target /tmp/r/$tag
      echo "--- $tag ---"
      find /tmp/r/$tag -type f -printf '%s %p\n' | sort -nr | head -8
    done
    rm -rf /tmp/r

Empty / absurdly tiny output for any target ⇒ that target's
backup is broken; check the most recent CronJob log.

## Total-loss disaster recovery

Cluster + node disk + local repo clone all gone. You have:

  - the restic passphrase (from your password manager)
  - the B2 access key id + secret (from your password manager
    or B2 console)
  - the bucket name + endpoint (from B2 console)

Steps:

1. Pull the restore scripts back.

       export RESTIC_REPOSITORY=s3:<endpoint>/<bucket>
       export RESTIC_PASSWORD=<passphrase>
       export AWS_ACCESS_KEY_ID=<key-id>
       export AWS_SECRET_ACCESS_KEY=<key-secret>
       restic snapshots --tag scripts          # confirm repo opens
       mkdir -p /tmp/scripts
       restic restore latest --tag scripts --target /tmp/scripts

   `/tmp/scripts/` now has every `restore-*.sh` plus this README.
   No git clone needed.

2. Pull operator config back. Lands `.env`, `config/`, and the
   most recent `terraform.tfstate.snapshot.json` into the target
   directory.

       /tmp/scripts/restore-config.sh latest ~/platform-restored

   `git clone <repo>` to the same target if the platform git
   tree is also gone — operator config goes on top, no
   conflicts (the gitignored files don't overlap with the
   tracked ones).

3. Bring up a fresh cluster.

       cd ~/platform-restored
       ./tf bootstrap-k3s

4. `./tf apply` — recreates the empty Postgres / MySQL / Redis /
   Vault / Stalwart shells.

5. Restore database data into the new pods, in order:

       /tmp/scripts/restore-postgres.sh <db> latest    # for each
       /tmp/scripts/restore-mysql.sh <db> latest       # for each
       /tmp/scripts/restore-redis.sh latest
       /tmp/scripts/restore-vault.sh latest

6. For each PV target listed in `services.backup.pv_paths`, scale
   its consumer to 0, restore the tarball, scale back up:

       kubectl -n <ns> scale deploy/<workload> --replicas=0
       PV_TARGET_PATH=<path> /tmp/scripts/restore-pv.sh <name> latest
       kubectl -n <ns> scale deploy/<workload> --replicas=1

7. Smoke-test the public surface (sign in, send a test email,
   open one tenant site). Verify `kubectl -n backups get
   cronjobs` is healthy so future backups land in the recreated
   repository.

## Things to know

- **Live-tar of stateful PV directories** trades a tiny window
  of in-flight writes against zero downtime on the source
  workload. RocksDB / SQLite / etc. that ship a write-ahead log
  recover cleanly to the most recent fsync; cooperative apps
  with a snapshot API (Vault) are backed up via that API
  instead.
- **`./tf backup-config` runs `terraform state pull` first** and
  bundles the JSON snapshot into the `operator-config` tag. Same
  encryption, separate B2 key. Disaster recovery doesn't have to
  assume the tfstate bucket survived.
- **Single passphrase** for the whole repo — losing it is total
  loss. Per-target passphrases are an option restic supports but
  this platform doesn't use; the trade-off is operator
  convenience over leak blast radius.
- **No automatic restore drill.** Verify periodically with the
  sanity-check section above; "not tested" backups are the
  classic failure mode.
