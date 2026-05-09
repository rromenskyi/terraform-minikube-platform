# zitadel

Zitadel identity provider — Postgres-backed StatefulSet, init Job, OIDC instance, default org + admin user, and provider transport (port-forward fallback for gRPC-trailers-stripping ingress chains).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 1.19.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.login_ingress_route](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_config_map_v1.steps](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.zitadel](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_job_v1.postgres_setup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_role_binding_v1.pat_broker](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.pat_broker](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |
| [kubernetes_secret_v1.login_client_pat](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.zitadel](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.pat_broker](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.zitadel](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.zitadel_login](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.masterkey](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_external_domain"></a> [external\_domain](#input\_external\_domain) | Public hostname Zitadel issues tokens for (e.g. id.example.com). Sets ExternalDomain — every OIDC issuer URL, redirect callback and email link references this host. Changing it later invalidates existing client redirect URIs. | `string` | n/a | yes |
| <a name="input_first_admin_email"></a> [first\_admin\_email](#input\_first\_admin\_email) | Email address of the bootstrap human admin (lands on the master instance). Pre-verified so login works without SMTP. | `string` | n/a | yes |
| <a name="input_postgres_host"></a> [postgres\_host](#input\_postgres\_host) | In-cluster Postgres hostname (e.g. postgres.platform.svc.cluster.local). | `string` | n/a | yes |
| <a name="input_postgres_superuser_secret"></a> [postgres\_superuser\_secret](#input\_postgres\_superuser\_secret) | Name of the Secret (in this namespace) holding the Postgres superuser password. Used by the bootstrap Job to CREATE DATABASE / CREATE ROLE. | `string` | n/a | yes |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy Zitadel. When false, no resources are created. | `bool` | `true` | no |
| <a name="input_first_admin_username"></a> [first\_admin\_username](#input\_first\_admin\_username) | Username for the bootstrap human admin. | `string` | `"zitadel-admin"` | no |
| <a name="input_image"></a> [image](#input\_image) | Zitadel main container image. v4 dropped the embedded Angular login form — the login UI now lives in the separate Next.js sidecar (`login_image`). Together with the FirstInstance machine-user PAT we bootstrap to disk, the chicken-and-egg of provisioning login-v2's service account vanishes. | `string` | `"ghcr.io/zitadel/zitadel:v4.14.0"` | no |
| <a name="input_login_client_pat"></a> [login\_client\_pat](#input\_login\_client\_pat) | Pre-existing PAT for the `login-client` machine user. FIRSTINSTANCE writes a fresh PAT to an emptyDir on first install; that file is lost on pod restart and the Login UI v2 sidecar hangs forever waiting for it. Setting this var to an existing PAT (regenerated via the management API once and pasted into the operator's `.env`) makes the deployment mount it from a Secret instead, surviving any number of pod restarts. Empty (default) keeps the original FIRSTINSTANCE-only behavior — fine on a fresh install, broken on every subsequent restart. | `string` | `""` | no |
| <a name="input_login_image"></a> [login\_image](#input\_login\_image) | Zitadel Login UI v2 sidecar image. Pinned to the last tagged release — the rolling `:main` tag has been observed to ship a SPA race that double-submits `createCallback` and trips `Auth Request has already been handled (COMMAND-Sx208nt)` on every OIDC flow, breaking forward-auth-style gates. The wait-for-token-file behaviour we used to need from `:main` is now done in this module's own container `command` override, so the tagged release is fine. | `string` | `"ghcr.io/zitadel/login:v3.0.1"` | no |
| <a name="input_login_policy"></a> [login\_policy](#input\_login\_policy) | Default Login Policy applied at FIRSTINSTANCE bootstrap. Sets the<br/>instance-wide gate for self-service registration, external IDP<br/>federation, and username/password login. Secure default: registration<br/>OFF (operator decides who joins; nobody self-onboards), Google/SAML<br/>federation ON (so wired IDPs work), username/password ON (so the<br/>bootstrap admin can log in).<br/><br/>NOTE: FIRSTINSTANCE config takes effect only on the very first boot<br/>against an empty database. Tweaking these values on an existing<br/>instance is what the root `zitadel_default_login_policy.main`<br/>resource (in `zitadel.tf`) is for — it reads this same struct via<br/>`local.platform.services.zitadel.login_policy` and reconciles<br/>against the live instance every apply. | <pre>object({<br/>    allow_register          = optional(bool, false)<br/>    allow_external_idp      = optional(bool, true)<br/>    allow_username_password = optional(bool, true)<br/>  })</pre> | `{}` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace Zitadel lives in. Expected to exist already (root-owned `platform`). Null when disabled. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels every Zitadel pod (main + login + Jobs) must match. Empty = scheduler picks. Set to pin onto the node carrying the platform's stateful tier. | `map(string)` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints every Zitadel pod tolerates. Empty list = pod cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_admin_password"></a> [admin\_password](#output\_admin\_password) | Bootstrap human admin password. Change in the UI on first login. Only re-emitted if the random\_password resource is replaced. |
| <a name="output_admin_username"></a> [admin\_username](#output\_admin\_username) | Bootstrap human admin username — only meaningful right after first apply. |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_external_domain"></a> [external\_domain](#output\_external\_domain) | Public hostname Zitadel issues tokens for. |
| <a name="output_host"></a> [host](#output\_host) | In-cluster FQDN for Zitadel. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where Zitadel runs, or null if disabled. |
| <a name="output_port"></a> [port](#output\_port) | Service port (HTTP, plain — TLS terminates at Cloudflare). |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | In-cluster Service name for Zitadel. |
<!-- END_TF_DOCS -->
