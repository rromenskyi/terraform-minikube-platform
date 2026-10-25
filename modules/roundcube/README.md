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

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |
| <a name="module_volume_seed"></a> [volume\_seed](#module\_volume\_seed) | ../volume-seed | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_config_map_v1.roundcube_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.roundcube_data](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.roundcube_secrets](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.roundcube](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.des_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [zitadel_application_oidc.roundcube](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/application_oidc) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | n/a | `string` | `"500m"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | n/a | `string` | `"20m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | n/a | `bool` | `true` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Roundcube is reachable at (the same one Stalwart uses; Roundcube serves root, Stalwart admin lives at /admin and /account). | `string` | n/a | yes |
| <a name="input_image"></a> [image](#input\_image) | Roundcube container image. The Apache flavour is used because the upstream image bakes a working PHP+Apache config; the alpine-fpm flavour needs an extra fpm/nginx pair. | `string` | `"roundcube/roundcubemail:1.6.20-apache@sha256:60601760a965be491bc5d3fc2da498153b85fed2d80fc903a4582ef71220e435"` | no |
| <a name="input_imap_host"></a> [imap\_host](#input\_imap\_host) | In-cluster Stalwart IMAP service host. TLS on port 993 (`tls://...`). | `string` | `"stalwart.mail.svc.cluster.local"` | no |
| <a name="input_imap_port"></a> [imap\_port](#input\_imap\_port) | n/a | `number` | `993` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | n/a | `string` | `"512Mi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | n/a | `string` | `"128Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | n/a | `string` | n/a | yes |
| <a name="input_smtp_host"></a> [smtp\_host](#input\_smtp\_host) | In-cluster Stalwart submission service host. TLS on port 465 (`ssl://...`). | `string` | `"stalwart.mail.svc.cluster.local"` | no |
| <a name="input_smtp_port"></a> [smtp\_port](#input\_smtp\_port) | n/a | `number` | `465` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for the SQLite volume. Empty: a hostPath PV under `volume_base_path` (the original layout). Set: a dynamic PVC `data-roundcube`; the database lives in its `data/` directory. | `string` | `""` | no |
| <a name="input_storage_seed_node"></a> [storage\_seed\_node](#input\_storage\_seed\_node) | With `storage_class` set: the node holding the old hostPath directory. On the first start an init container copies it into the new volume (only into an empty one; marker `.seeded`), and the pod is pinned to this node meanwhile. Clear it once the data has moved. | `string` | `""` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Root directory on the host node for Roundcube's preferences SQLite DB. | `string` | n/a | yes |
| <a name="input_volume_node_label"></a> [volume\_node\_label](#input\_volume\_node\_label) | Node label the pod requires (operator `Exists`) when its data is on `storage_class`: the label a CSI driver puts on the nodes where its node plugin runs (LINSTOR: `linbit.com/hostname`), so the pod is never scheduled onto a node where the volume cannot attach. Empty = no constraint. | `string` | `""` | no |
| <a name="input_volume_preferred_node_selectors"></a> [volume\_preferred\_node\_selectors](#input\_volume\_preferred\_node\_selectors) | Node selectors (label => value) of the nodes holding copies of `storage_class` volumes, e.g. the LINSTOR storage pool's `node_selector`. With the data on `storage_class` the pod prefers those nodes (one `preferredDuringScheduling` term per selector, weight 100), so its data is a local copy. Empty = no preference. | `list(map(string))` | `[]` | no |
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
