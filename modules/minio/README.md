# minio

MinIO — S3-compatible object store for the platform.

Single-replica Deployment + PVC. Use case: per-tenant archive
buckets where the consuming workload needs an S3 endpoint and the
operator doesn't want a cloud dependency. Engine emits one
bucket-credentials Secret per `buckets:` entry in the operator
config; the consumer chart `envFrom`s it (standard
`S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` / `S3_ENDPOINT` /
`S3_REGION` / `S3_BUCKET` / `S3_PATH_STYLE` keys).

MinIO's bundled IAM is shared per-instance — the engine creates
one root credential for itself and per-bucket service-account
keys for tenants. Per-bucket auto-creation runs as a Kubernetes
Job (mc cli image) that mc-aliases the root creds + `mc mb` +
`mc admin user svcacct add` for each bucket; idempotent across
applies.

Storage class operator-supplied via `var.storage_class`. Empty =
default (hostPath / local-path on k3s); set to a Longhorn pool SC
for cross-node replication.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
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
| [kubernetes_deployment_v1.minio](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_job_v1.buckets](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.minio](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.minio_static](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.consumer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.root](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.minio](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.minio_headless](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.minio](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [random_password.consumer_access_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.consumer_secret_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.root_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.root_user](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_buckets"></a> [buckets](#input\_buckets) | Buckets the engine pre-creates and exposes via per-consumer Secrets. Map key is the bucket name (must match S3 naming rules: lowercase + dash). Each entry: `region` (string the SDK expects in `S3_REGION`; MinIO ignores it but boto3 / aws-sdk-go demand a value — default `auto` is universally accepted), `consumers` (list of `{namespace, secret_name}` — every consumer gets its own MinIO service-account key + its own Secret in its own namespace, so leakage of one Secret limits blast radius to that service-account and is revocable without bucket recreation; multiple consumers on the same bucket share data — same `s3:*` policy on the bucket per service-account, no per-consumer prefix scoping yet). Empty map = MinIO server runs but no buckets are pre-created. | <pre>map(object({<br/>    region = optional(string, "auto")<br/>    consumers = list(object({<br/>      namespace   = string<br/>      secret_name = string<br/>    }))<br/>  }))</pre> | `{}` | no |
| <a name="input_distributed"></a> [distributed](#input\_distributed) | Optional distributed MinIO topology — `enabled = true` switches the module from a single-replica `Deployment` + one PVC to a `StatefulSet` with N replicas, each backed by its own PVC, with a headless Service for pod-to-pod traffic and `MINIO_VOLUMES` pointing at the per-pod hostnames so MinIO erasure-codes objects across the pool. The minimum legal `replica_count` is 4 (MinIO erasure coding requires at least 4 disks); `5` matches a single-pod-per-node spread on this 5-node cluster. Per-pod `storage_size` (set on `var.storage_size`) — total raw capacity is `storage_size × replica_count`, usable capacity is roughly `(replica_count - parity) × storage_size` (default parity 1, so 4 of 5 = 80% efficient on a 5-pod cluster). Anti-affinity spreads pods one-per-node by `kubernetes.io/hostname`. Empty / `enabled = false` keeps the standalone Deployment shape unchanged. Optional `hostpath_pvs` block opts into operator-pinned static `PersistentVolume`s (one per replica) backed by `hostPath` on a specific node — engine emits the PVs with `claimRef` pre-binding to the StatefulSet's `data-minio-<N>` PVCs, MinIO's app-layer erasure coding handles HA, no dynamic provisioner / Longhorn replication double-redundancy. When set: `node_hosts` is the per-replica hostname pin (length must equal `replica_count`) and `base_path` is the parent dir on each node — pod N gets `<base_path>/<N>` with `hostPath.type: DirectoryOrCreate`, kubelet auto-mkdir's at first attach. When omitted, the StatefulSet falls back to dynamic PVCs via `var.storage_class`. | <pre>object({<br/>    enabled       = optional(bool, false)<br/>    replica_count = optional(number, 4)<br/>    hostpath_pvs = optional(object({<br/>      base_path  = string<br/>      node_hosts = list(string)<br/>    }))<br/>  })</pre> | `{}` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy MinIO. False collapses every resource. | `bool` | `false` | no |
| <a name="input_image"></a> [image](#input\_image) | MinIO server container image. Pinned by tag — auto-update is opt-in via operator bumping the tag. | `string` | `"minio/minio:RELEASE.2025-09-07T16-13-09Z"` | no |
| <a name="input_mc_image"></a> [mc\_image](#input\_mc\_image) | MinIO Client image used by the bucket-provisioning Job. `mc admin user svcacct` shape is stable across recent releases. Tag is verified-pullable; bump as upstream cuts new releases. | `string` | `"minio/mc:RELEASE.2025-08-13T08-35-41Z"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace MinIO lives in. Convention is `platform`; the chart's bucket Secrets land in the consumer namespaces (see `var.buckets`), not here. | `string` | `"platform"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector for the MinIO pod. Empty = scheduler picks. Pin to the `stateful` tier on a single-node-PV cluster so the PVC's local data dir is always reachable. | `map(string)` | `{}` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the MinIO PVC. Empty = cluster default (typically `local-path` on k3s, single-node hostPath). Set to a Longhorn pool SC name (e.g. `longhorn-stateful`) for cross-node replication so node-loss events re-attach the volume to a surviving node. | `string` | `""` | no |
| <a name="input_storage_size"></a> [storage\_size](#input\_storage\_size) | PVC size for the MinIO data volume. Sized by what's archived — recordings dominate (typical sip-recorder WAV is ~1 MB / minute of call). Bump when archival cardinality grows. | `string` | `"50Gi"` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations for the MinIO pod. Empty = un-tainted nodes only. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string, "Exists")<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_secret_names"></a> [bucket\_secret\_names](#output\_bucket\_secret\_names) | Map of bucket name → list of `{namespace, secret_name}` for every consumer Secret emitted on that bucket. Empty when no buckets configured or module disabled. |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | Whether the module emitted any resources. |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | Cluster-internal S3 API URL. Empty when disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Service name for the MinIO API. Empty when disabled. |
<!-- END_TF_DOCS -->
