# postgres

Cluster-internal PostgreSQL StatefulSet for tenant component databases. Per-component DB + role + grant are provisioned by `modules/project` against this shared instance.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_job_v1.pg_extensions](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.postgres](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.postgres](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.superuser](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.postgres](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.postgres](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [random_password.superuser](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the PostgreSQL StatefulSet. When `false`, no resources are created and every output collapses to null. | `bool` | `true` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the PostgreSQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it. Null when `enabled = false`. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels the Postgres pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`). | `map(string)` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints the Postgres pod tolerates. Empty list = pod cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PersistentVolume for PostgreSQL data. Lands at <volume\_base\_path>/<namespace>/postgres/. | `string` | `"/data/vol"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_host"></a> [host](#output\_host) | PostgreSQL in-cluster hostname, or null if disabled. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where PostgreSQL is deployed, or null if disabled. |
| <a name="output_port"></a> [port](#output\_port) | PostgreSQL Service port, or null if disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | PostgreSQL Service name, or null if disabled. |
| <a name="output_superuser_password"></a> [superuser\_password](#output\_superuser\_password) | Password for the `postgres` superuser (also in the postgres-superuser Secret). Null if disabled. |
| <a name="output_superuser_secret_name"></a> [superuser\_secret\_name](#output\_superuser\_secret\_name) | Name of the Secret holding the superuser password. The tenant-provisioner Job reads it when creating per-tenant DBs. Null if disabled. |
<!-- END_TF_DOCS -->
