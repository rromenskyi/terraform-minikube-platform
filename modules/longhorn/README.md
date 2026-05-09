# longhorn

Longhorn — distributed block storage.

Replaces the per-node hostPath PV pattern for any tenant
component that opts in via `storage_class: longhorn`. Volumes
are replicated across the cluster (default 3 replicas, one per
node), so the consuming pod can schedule on any node and
Longhorn attaches the right replica locally.

Backups land on the same B2 bucket the restic pipeline uses,
under a dedicated `longhorn-volumes/` prefix — Longhorn's
native backup format isn't restic-compatible, so the two
pipelines stay side-by-side rather than one feeding the other.
Recurring jobs (daily backup, retention) are configured by
annotation on the StorageClass and apply to every volume of
that class.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.longhorn](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.recurring_backup](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_secret_v1.backup_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_storage_class_v1.tag_pool](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_backup_b2_access_key_id"></a> [backup\_b2\_access\_key\_id](#input\_backup\_b2\_access\_key\_id) | B2 application key id with read/write to `backup_b2_bucket`. Sourced from the operator's gitignored `.env`. | `string` | `""` | no |
| <a name="input_backup_b2_bucket"></a> [backup\_b2\_bucket](#input\_backup\_b2\_bucket) | B2 bucket for Longhorn native backups. May share the bucket with the restic backup pipeline; Longhorn's data lands under a separate `longhorn-volumes/` prefix automatically. Empty disables backup-target configuration; volumes still work, just can't be backed up via Longhorn's `BackupTarget` API. | `string` | `""` | no |
| <a name="input_backup_b2_endpoint"></a> [backup\_b2\_endpoint](#input\_backup\_b2\_endpoint) | S3-compatible endpoint URL for the B2 region (`https://s3.<region>.backblazeb2.com`). Required when `backup_b2_bucket` is set. | `string` | `""` | no |
| <a name="input_backup_b2_region"></a> [backup\_b2\_region](#input\_backup\_b2\_region) | Token Longhorn embeds in the `s3://<bucket>@<region>/` URL. B2 doesn't enforce AWS regional routing; the value just has to be non-empty. Uses the bucket region name from the endpoint by default. | `string` | `"us-east-005"` | no |
| <a name="input_backup_b2_secret_access_key"></a> [backup\_b2\_secret\_access\_key](#input\_backup\_b2\_secret\_access\_key) | B2 application key secret matching `backup_b2_access_key_id`. | `string` | `""` | no |
| <a name="input_default_data_path"></a> [default\_data\_path](#input\_default\_data\_path) | Host directory each Longhorn instance-manager pod writes replica data to. Should NOT be the same path the platform's hostPath PVs use — keep blast radius separate. | `string` | `"/var/lib/longhorn/"` | no |
| <a name="input_default_replica_count"></a> [default\_replica\_count](#input\_default\_replica\_count) | Number of replicas Longhorn maintains for every new volume. 3 = one per node on a 3-node cluster (default). 1 keeps the volume single-node — useful for single-node dev clusters where the durability guarantee doesn't apply anyway. | `number` | `3` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy Longhorn. False collapses every resource. | `bool` | `false` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace Longhorn lives in. Convention is `longhorn-system`; the chart hardcodes it for several internal references, so override only if a fleet-wide policy requires a different one. | `string` | `"longhorn-system"` | no |
| <a name="input_recurring_backup_cron"></a> [recurring\_backup\_cron](#input\_recurring\_backup\_cron) | Cron schedule (UTC) for the per-volume daily backup RecurringJob applied to the `longhorn` StorageClass. Default 04:30 UTC — late enough that the platform restic backups (03:00–04:00 UTC) are done so the two pipelines don't compete for B2 bandwidth. | `string` | `"30 4 * * *"` | no |
| <a name="input_recurring_backup_retain"></a> [recurring\_backup\_retain](#input\_recurring\_backup\_retain) | Number of daily backups Longhorn keeps per volume before pruning. Pair with `recurring_backup_cron` — together they define the per-volume retention window. | `number` | `7` | no |
| <a name="input_tag_pools"></a> [tag\_pools](#input\_tag\_pools) | Operator-defined topology pools. Each entry causes the engine to emit a sibling StorageClass named `longhorn-<key>` whose volumes are constrained to nodes carrying the specified Longhorn node tag (and optionally with a custom replica count + reclaim policy). Operator decides which pools exist (keys are operator-named, e.g. `home`, `edge`, `fast-ssd`) and tags the matching nodes one-time via `kubectl -n longhorn-system patch node.longhorn.io <name> --type=merge -p '{"spec":{"tags":["<key>"]}}'`. Consumers (e.g. `services.redis.storage_class`) opt in by referencing `longhorn-<key>` SC name. Empty map (default) emits no extra SCs — only the default `longhorn` SC the chart creates is in play. | <pre>map(object({<br/>    replicas       = optional(number, 2)<br/>    reclaim_policy = optional(string, "Delete")<br/>    fs_type        = optional(string, "ext4")<br/>    data_locality  = optional(string, "best-effort")<br/>  }))</pre> | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations propagated to every Longhorn pod (manager DaemonSet, CSI components, UI, instance-managers). Empty = Longhorn pods land only on un-tainted nodes; on a tainted-edge or tainted-control-plane setup the storage layer must tolerate the same taints workloads do, otherwise replicas can't bind to those nodes and `replicaCount` can't be satisfied. Standard k8s toleration shape — passed both to the chart's `longhornManager` / `longhornUI` / `longhornDriver` values AND rendered into the Longhorn-format `taintToleration` setting for dynamic instance-managers. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string, "Exists")<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_version_pin"></a> [version\_pin](#input\_version\_pin) | Helm chart version for longhorn/longhorn. Pinned so an upstream re-tag doesn't change behavior across applies. | `string` | `"1.11.1"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_backup_target"></a> [backup\_target](#output\_backup\_target) | Longhorn S3 backup target URL, or null when backup is unconfigured. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Longhorn namespace, null when disabled. |
| <a name="output_storage_class"></a> [storage\_class](#output\_storage\_class) | StorageClass name to set on PVCs that should land on Longhorn-managed volumes. The chart creates the class itself; this output is just a stable reference for callers. |
<!-- END_TF_DOCS -->
