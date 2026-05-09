# platform-dash

Operator dashboard (SvelteKit) Deployment + Service. OIDC integration is wired by the root `platform_dash.tf` calling `modules/zitadel-app` and feeding the Secret name in.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_cluster_role_binding_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_deployment_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_service_account_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy the dashboard. Off → all resources count = 0. | `bool` | n/a | yes |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname the dashboard answers on. Embedded as ORIGIN / AUTH\_URL so cookie + OIDC redirect generation produces the right scheme + host even when behind cloudflared. | `string` | n/a | yes |
| <a name="input_image"></a> [image](#input\_image) | Container image, tag included. | `string` | n/a | yes |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace to deploy into. Conventionally the shared `platform` namespace once promoted to first-class infra. | `string` | n/a | yes |
| <a name="input_oidc_secret_checksum"></a> [oidc\_secret\_checksum](#input\_oidc\_secret\_checksum) | SHA1 of the OIDC Secret data, mounted as a `checksum/oidc` annotation so a Zitadel app rotation rolls the pod automatically. | `string` | n/a | yes |
| <a name="input_oidc_secret_name"></a> [oidc\_secret\_name](#input\_oidc\_secret\_name) | Name of the Secret in `namespace` that holds AUTH\_ZITADEL\_ISSUER / AUTH\_ZITADEL\_ID / AUTH\_ZITADEL\_SECRET / AUTH\_SECRET. Produced by modules/zitadel-app. | `string` | n/a | yes |
| <a name="input_resources"></a> [resources](#input\_resources) | Pod resource requests/limits. | <pre>object({<br/>    requests = map(string)<br/>    limits   = map(string)<br/>  })</pre> | n/a | yes |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels the platform-dash pod must match. Empty = scheduler picks. The dash is stateless and can run anywhere; pin via `{ workload-tier = general }` or similar to keep it off the data node. | `map(string)` | `{}` | no |
| <a name="input_replicas"></a> [replicas](#input\_replicas) | Replica count. Defaults to 1; the dashboard is read-mostly so a single pod is enough. | `number` | `1` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints the platform-dash pod tolerates. Empty list = pod cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where the dashboard lives. Null when disabled. |
| <a name="output_service_account_name"></a> [service\_account\_name](#output\_service\_account\_name) | ServiceAccount name. Null when disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | ClusterIP Service name (for IngressRoute target). Null when disabled. |
| <a name="output_service_port"></a> [service\_port](#output\_service\_port) | Service port the IngressRoute should target. |
<!-- END_TF_DOCS -->
