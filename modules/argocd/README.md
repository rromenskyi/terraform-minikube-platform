# argocd

Argo CD — application-layer GitOps controller.

Deploys the upstream `argo/argo-cd` Helm chart with the chart-side
Ingress disabled. The platform owns ingress concerns elsewhere
(Cloudflare Tunnel + Traefik IngressRoute) so the route lands as a
`kind: external` component pointing at the `argocd-server` Service
this chart creates.

OIDC is wired through Dex's built-in OIDC connector. Caller is
responsible for creating the Zitadel application (see
`argocd.tf` at the root) and passing in `client_id` /
`client_secret`. Empty inputs collapse the OIDC config and the
install falls back to the chart-generated local `admin` account.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.argocd](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Argo CD answers on. Embedded as `server.config.url` so generated redirect URIs and webhook callbacks resolve back to the public face. | `string` | n/a | yes |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy Argo CD. False collapses every resource — single-node clusters that don't need GitOps stay clean. | `bool` | `false` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace Argo CD lives in. Created by the chart's `create_namespace = true` so the operator doesn't have to declare it elsewhere. | `string` | `"argocd"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector applied to every Argo CD pod the chart creates (server, repo-server, application-controller, redis, dex). Empty = scheduler picks. Set on multi-node clusters where a specific tier should host the GitOps controller. | `map(string)` | `{}` | no |
| <a name="input_oidc_admin_groups"></a> [oidc\_admin\_groups](#input\_oidc\_admin\_groups) | Group / role claims granted Argo CD's `role:admin` policy. Anyone whose ID token carries one of these claims gets full read/write across every Application/AppProject. Empty list = OIDC users have no permissions until the operator hand-edits the in-cluster ConfigMap. | `list(string)` | `[]` | no |
| <a name="input_oidc_client_id"></a> [oidc\_client\_id](#input\_oidc\_client\_id) | Client ID for the OIDC application Argo CD uses. Caller is responsible for creating the application in Zitadel and propagating the value here. | `string` | `""` | no |
| <a name="input_oidc_client_secret"></a> [oidc\_client\_secret](#input\_oidc\_client\_secret) | Client secret for the OIDC application Argo CD uses. Sensitive — the value lands in a Helm-managed Secret inside the cluster. | `string` | `""` | no |
| <a name="input_oidc_issuer"></a> [oidc\_issuer](#input\_oidc\_issuer) | OIDC issuer URL. When set together with `oidc_client_id` and `oidc_client_secret`, the chart wires Dex with an OIDC connector and the UI gets a `Sign in with OIDC` button. Empty inputs disable the integration; only the chart-generated local admin remains. | `string` | `""` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints every Argo CD pod tolerates. Empty list = pods cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_version_pin"></a> [version\_pin](#input\_version\_pin) | Helm chart version for argo/argo-cd. Pinned so an upstream re-tag doesn't silently change behavior across applies. Bump deliberately when a new chart fixes a CVE or ships a desired feature. | `string` | `"9.5.11"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace Argo CD lives in. Null when disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | ClusterIP Service name for the Argo CD UI/API. Wired into a `kind: external` component yaml so the IngressRoute pipeline routes the public hostname here. Null when disabled. |
| <a name="output_service_port"></a> [service\_port](#output\_service\_port) | Service port the IngressRoute should target. Null when disabled. |
<!-- END_TF_DOCS -->
