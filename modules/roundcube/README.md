# roundcube

Roundcube webmail Deployment + PVC for the bundled mail stack. Talks to the Stalwart SMTP / IMAP services in the same namespace.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_zitadel"></a> [zitadel](#requirement\_zitadel) | ~> 2.9 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_zitadel"></a> [zitadel](#provider\_zitadel) | ~> 2.9 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_config_map_v1.roundcube_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.roundcube_secrets](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.des_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [zitadel_application_oidc.roundcube](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/application_oidc) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Roundcube is reachable at (the same one Stalwart uses; Roundcube serves root, Stalwart admin lives at /admin and /account). | `string` | n/a | yes |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | n/a | `string` | n/a | yes |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Root directory on the host node for Roundcube's preferences SQLite DB. | `string` | n/a | yes |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | n/a | `string` | `"500m"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | n/a | `string` | `"20m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | n/a | `bool` | `true` | no |
| <a name="input_image"></a> [image](#input\_image) | Roundcube container image. The Apache flavour is used because the upstream image bakes a working PHP+Apache config; the alpine-fpm flavour needs an extra fpm/nginx pair. | `string` | `"roundcube/roundcubemail:1.6.10-apache"` | no |
| <a name="input_imap_host"></a> [imap\_host](#input\_imap\_host) | In-cluster Stalwart IMAP service host. TLS on port 993 (`tls://...`). | `string` | `"stalwart.mail.svc.cluster.local"` | no |
| <a name="input_imap_port"></a> [imap\_port](#input\_imap\_port) | n/a | `number` | `993` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | n/a | `string` | `"512Mi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | n/a | `string` | `"128Mi"` | no |
| <a name="input_smtp_host"></a> [smtp\_host](#input\_smtp\_host) | In-cluster Stalwart submission service host. TLS on port 465 (`ssl://...`). | `string` | `"stalwart.mail.svc.cluster.local"` | no |
| <a name="input_smtp_port"></a> [smtp\_port](#input\_smtp\_port) | n/a | `number` | `465` | no |
| <a name="input_zitadel_issuer_url"></a> [zitadel\_issuer\_url](#input\_zitadel\_issuer\_url) | n/a | `string` | `""` | no |
| <a name="input_zitadel_org_id"></a> [zitadel\_org\_id](#input\_zitadel\_org\_id) | n/a | `string` | `""` | no |
| <a name="input_zitadel_project_id"></a> [zitadel\_project\_id](#input\_zitadel\_project\_id) | Existing Zitadel project this Roundcube OIDC app lands under. Reusing the Stalwart-tenant project keeps role grants in one place. | `string` | `""` | no |
| <a name="input_zitadel_provider_authenticated"></a> [zitadel\_provider\_authenticated](#input\_zitadel\_provider\_authenticated) | n/a | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | ── Outputs ─────────────────────────────────────────────────────────────────── |
| <a name="output_zitadel_application_oidc_id"></a> [zitadel\_application\_oidc\_id](#output\_zitadel\_application\_oidc\_id) | n/a |
<!-- END_TF_DOCS -->
