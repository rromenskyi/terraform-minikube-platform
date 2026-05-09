# mysql

Cluster-internal MySQL StatefulSet for tenant component databases. Per-component DB + user + grant are provisioned by `modules/project` against this shared instance.

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
| [kubernetes_persistent_volume_claim_v1.mysql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.mysql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.mysql_root](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.mysql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.mysql](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [random_password.root](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the MySQL StatefulSet. When `false`, no resources are created and every output collapses to null — a disabled MySQL cleanly cascades into `modules/project` (components with `db: true` fail a precondition instead of silently deploying a broken StatefulSet). | `bool` | `true` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the MySQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it so the sibling Postgres/Redis/Ollama modules can share the same namespace without piggybacking on this module. Null when `enabled = false`. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels the MySQL pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`). | `map(string)` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints the MySQL pod tolerates. Empty list = pod cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PersistentVolume for MySQL data. MySQL lands at <volume\_base\_path>/<namespace>/mysql/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol). | `string` | `"/data/vol"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_host"></a> [host](#output\_host) | MySQL in-cluster hostname, or null if the module is disabled. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where MySQL is deployed, or null if the module is disabled. |
| <a name="output_port"></a> [port](#output\_port) | MySQL Service port, or null if the module is disabled. |
| <a name="output_root_password"></a> [root\_password](#output\_root\_password) | MySQL root password (also in the mysql-root Secret), or null if the module is disabled. |
| <a name="output_root_secret_name"></a> [root\_secret\_name](#output\_root\_secret\_name) | Name of the Secret carrying MYSQL\_ROOT\_PASSWORD. Consumed by the backup module's cross-namespace mirror Secret. Null when disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | MySQL Service name, or null if the module is disabled. |
<!-- END_TF_DOCS -->
