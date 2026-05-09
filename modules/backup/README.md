# backup

Platform backups → Backblaze B2 via restic.

One restic repository on a dedicated B2 bucket carries every
backup target (Postgres dumps, MySQL dumps, Redis snapshots,
Vault raft snapshots, hostPath PV tarballs, operator-side
config/.env). Encryption is built into restic (AES-256 + a
single passphrase shared across targets). Retention is
`restic forget --prune` on a weekly cron with daily/weekly/
monthly slots.

Restore scripts ship in this module's `scripts/` directory and
are pushed into the restic repo as a `scripts` tag on every
init Job run, so a complete cluster wipe + lost local repo
still leaves the operator with `restic restore latest --tag
scripts → run` as the disaster-recovery starting point.

Three layers of secret storage make passphrase loss survivable:
  - Generated once via `random_password.backup_passphrase`,
    surfaced as a sensitive Terraform output. Operator pastes
    into a personal password manager — that is the only
    long-term source of truth.
  - Mounted into in-cluster CronJobs via a k8s Secret in this
    module's namespace.
  - Operator's `.env` may carry it as `TF_VAR_backup_passphrase`
    for the wrapper-side `./tf backup-config` invocation;
    gitignored, never reaches the public repo.

B2 credentials are sourced from the same `.env` shape the
Terraform S3 backend already uses for tfstate
(`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), but pointed at
a dedicated `backups` bucket so a tfstate-key compromise can't
delete or overwrite backups.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_config_map_v1.restore_scripts](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_cron_job_v1.mysql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_cron_job_v1.postgres](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_cron_job_v1.prune](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_cron_job_v1.pv](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_cron_job_v1.redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_cron_job_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cron_job_v1) | resource |
| [kubernetes_job_v1.restic_init](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_namespace_v1.backup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.backup_creds](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_password.backup_passphrase](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_b2_access_key_id"></a> [b2\_access\_key\_id](#input\_b2\_access\_key\_id) | B2 application key ID with write access to `b2_bucket`. Sourced from the operator's `.env`. | `string` | n/a | yes |
| <a name="input_b2_bucket"></a> [b2\_bucket](#input\_b2\_bucket) | Backblaze B2 bucket name for backups. Should NOT be the same bucket the Terraform S3 backend uses for tfstate — keep blast radius separate. | `string` | n/a | yes |
| <a name="input_b2_endpoint"></a> [b2\_endpoint](#input\_b2\_endpoint) | S3-compatible endpoint URL for the B2 bucket region (e.g. `https://s3.us-east-005.backblazeb2.com`). Same shape as `B2_ENDPOINT` in the operator's `.env` for tfstate. | `string` | n/a | yes |
| <a name="input_b2_secret_access_key"></a> [b2\_secret\_access\_key](#input\_b2\_secret\_access\_key) | B2 application key secret matching `b2_access_key_id`. Sensitive — lands in a k8s Secret in `var.namespace`. | `string` | n/a | yes |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to provision backup CronJobs + restic init Job. False collapses every resource — fresh clones stay clean. | `bool` | `false` | no |
| <a name="input_image_alpine"></a> [image\_alpine](#input\_image\_alpine) | Alpine image used as the base for every backup CronJob. Each Job apk-installs the tools it needs (postgresql-client, mysql-client, redis, restic, …) at start. Pinned to keep behavior stable across applies. | `string` | `"alpine:3.22"` | no |
| <a name="input_mysql_databases"></a> [mysql\_databases](#input\_mysql\_databases) | List of MySQL database names to dump. Empty = `mysqldump --all-databases`. | `list(string)` | `[]` | no |
| <a name="input_mysql_enabled"></a> [mysql\_enabled](#input\_mysql\_enabled) | Whether to dump the shared MySQL on schedule. | `bool` | `false` | no |
| <a name="input_mysql_host"></a> [mysql\_host](#input\_mysql\_host) | In-cluster hostname for `mysqldump` connections. | `string` | `""` | no |
| <a name="input_mysql_root_secret"></a> [mysql\_root\_secret](#input\_mysql\_root\_secret) | Name of the Secret in `var.namespace` holding the MySQL root password under `MYSQL_ROOT_PASSWORD`. | `string` | `""` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the backup CronJobs run in. Created by this module so tenant ResourceQuotas stay isolated from backup workload. | `string` | `"backups"` | no |
| <a name="input_passphrase"></a> [passphrase](#input\_passphrase) | Passphrase used to encrypt the restic repository. Empty (default) lets the module generate a random 32-char value via `random_password`; operators that prefer to manage the passphrase out-of-band can pass a non-empty value here. Either way, the passphrase MUST be stored in the operator's password manager — losing it bricks every backup forever (restic AES-256 has no recovery path). | `string` | `""` | no |
| <a name="input_postgres_databases"></a> [postgres\_databases](#input\_postgres\_databases) | List of database names to dump on each Postgres backup run. Empty list = uses `pg_dumpall` instead, capturing everything in one stream. Per-database mode is preferred — restic dedup works better on smaller stable streams and a per-DB restore is simpler. | `list(string)` | `[]` | no |
| <a name="input_postgres_enabled"></a> [postgres\_enabled](#input\_postgres\_enabled) | Whether to dump the shared Postgres on schedule. Off by default — disable when there's no Postgres in the platform OR when the operator handles dumps out-of-band. | `bool` | `false` | no |
| <a name="input_postgres_host"></a> [postgres\_host](#input\_postgres\_host) | In-cluster hostname for `pg_dump` connections (e.g. `postgres.platform.svc.cluster.local`). | `string` | `""` | no |
| <a name="input_postgres_superuser_secret"></a> [postgres\_superuser\_secret](#input\_postgres\_superuser\_secret) | Name of the Secret in `var.namespace` (created by this module via cross-namespace copy from the postgres module's superuser Secret) holding the `POSTGRES_PASSWORD` key. The CronJob mounts it for `pg_dump` auth. | `string` | `""` | no |
| <a name="input_pv_enabled"></a> [pv\_enabled](#input\_pv\_enabled) | Whether to tar host-path PV directories on schedule. Pod runs with `hostNetwork = false` but `hostPath` mounts for each entry in `pv_paths`. Must run on the node that owns the data — set `pv_node_selector` accordingly. | `bool` | `false` | no |
| <a name="input_pv_node_selector"></a> [pv\_node\_selector](#input\_pv\_node\_selector) | Node-selector for the PV backup CronJob. Required on multi-node clusters where hostPath PVs live on a single node — without it the scheduler can land the Job where the host directory is empty. | `map(string)` | `{}` | no |
| <a name="input_pv_paths"></a> [pv\_paths](#input\_pv\_paths) | List of host-path entries to back up. Each entry is `{ name, path }` where `name` is a stable identifier used as the restic snapshot tag (e.g. `stalwart-data`) and `path` is the absolute host directory (e.g. `/data/vol/platform/stalwart/data`). | <pre>list(object({<br/>    name = string<br/>    path = string<br/>  }))</pre> | `[]` | no |
| <a name="input_pv_tolerations"></a> [pv\_tolerations](#input\_pv\_tolerations) | Tolerations for the PV backup CronJob. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_redis_default_secret"></a> [redis\_default\_secret](#input\_redis\_default\_secret) | Name of the Secret in `var.namespace` holding the Redis `default` user password under `REDIS_PASSWORD`. | `string` | `""` | no |
| <a name="input_redis_enabled"></a> [redis\_enabled](#input\_redis\_enabled) | Whether to snapshot Redis on schedule via `redis-cli --rdb`. | `bool` | `false` | no |
| <a name="input_redis_host"></a> [redis\_host](#input\_redis\_host) | In-cluster hostname for `redis-cli`. | `string` | `""` | no |
| <a name="input_retention_keep_daily"></a> [retention\_keep\_daily](#input\_retention\_keep\_daily) | How many daily restic snapshots to keep per target. | `number` | `7` | no |
| <a name="input_retention_keep_monthly"></a> [retention\_keep\_monthly](#input\_retention\_keep\_monthly) | How many monthly restic snapshots to keep per target. | `number` | `6` | no |
| <a name="input_retention_keep_weekly"></a> [retention\_keep\_weekly](#input\_retention\_keep\_weekly) | How many weekly restic snapshots to keep per target. | `number` | `4` | no |
| <a name="input_schedule_mysql"></a> [schedule\_mysql](#input\_schedule\_mysql) | Cron schedule for the MySQL dump CronJob (UTC). Offset 15 min from Postgres so the two don't pile up on the network at once. | `string` | `"15 3 * * *"` | no |
| <a name="input_schedule_postgres"></a> [schedule\_postgres](#input\_schedule\_postgres) | Cron schedule for the Postgres dump CronJob (UTC). | `string` | `"0 3 * * *"` | no |
| <a name="input_schedule_prune"></a> [schedule\_prune](#input\_schedule\_prune) | Cron schedule for the `restic forget --prune` retention CronJob (UTC). Weekly so the prune walk happens off-peak after the heaviest backup window. | `string` | `"0 5 * * 0"` | no |
| <a name="input_schedule_pv"></a> [schedule\_pv](#input\_schedule\_pv) | Cron schedule for the hostPath PV tar CronJob (UTC). Weekly default — tarballs are heavier than DB dumps, restic dedup keeps the weekly cadence cheap. | `string` | `"0 4 * * 0"` | no |
| <a name="input_schedule_redis"></a> [schedule\_redis](#input\_schedule\_redis) | Cron schedule for the Redis snapshot CronJob (UTC). | `string` | `"30 3 * * *"` | no |
| <a name="input_schedule_vault"></a> [schedule\_vault](#input\_schedule\_vault) | Cron schedule for the Vault raft snapshot CronJob (UTC). | `string` | `"45 3 * * *"` | no |
| <a name="input_vault_addr"></a> [vault\_addr](#input\_vault\_addr) | In-cluster Vault URL (e.g. `http://vault.platform.svc.cluster.local:8200`). | `string` | `""` | no |
| <a name="input_vault_enabled"></a> [vault\_enabled](#input\_vault\_enabled) | Whether to take a `vault operator raft snapshot save` on schedule. | `bool` | `false` | no |
| <a name="input_vault_token_secret"></a> [vault\_token\_secret](#input\_vault\_token\_secret) | Name of the Secret in `var.namespace` holding the Vault root token under `VAULT_TOKEN`. Phase 0 sources from the bootstrap Secret; future phases will use a dedicated backup-policy AppRole so the root token isn't day-to-day exposed. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Backups namespace, or null when disabled. |
| <a name="output_passphrase"></a> [passphrase](#output\_passphrase) | restic repository passphrase. Pull with `terraform output -raw backup_passphrase` (root output) and stash in a password manager — losing it bricks every backup. |
| <a name="output_repository_url"></a> [repository\_url](#output\_repository\_url) | restic repository URL (`s3:<endpoint>/<bucket>`). Used by the wrapper-side `./tf backup-config` command and by every restore-script. |
<!-- END_TF_DOCS -->
