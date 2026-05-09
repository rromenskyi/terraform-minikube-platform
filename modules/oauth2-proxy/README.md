# oauth2-proxy

OAuth2 Proxy sidecar wiring for components that opt into auth offloading. Pairs with a `modules/zitadel-app` instance per protected component.

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
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_zitadel"></a> [zitadel](#provider\_zitadel) | ~> 2.9 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.middleware_forward](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.middleware_proto](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_deployment_v1.oauth2_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_secret_v1.oauth2_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.oauth2_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.cookie_secret](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [zitadel_application_oidc.this](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/application_oidc) | resource |
| [zitadel_project.this](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_auth_hostname"></a> [auth\_hostname](#input\_auth\_hostname) | Public hostname this proxy answers on (e.g. auth.example.com). Used as the OIDC redirect URI host and as the auth-host (`/_oauth` callback lands here for every protected subdomain). | `string` | n/a | yes |
| <a name="input_cookie_domain"></a> [cookie\_domain](#input\_cookie\_domain) | Cookie scope. Set to the parent domain WITHOUT a leading dot (e.g. `example.com`) — traefik-forward-auth canonicalises this and emits cookies that cover every subdomain. | `string` | n/a | yes |
| <a name="input_issuer_url"></a> [issuer\_url](#input\_issuer\_url) | Zitadel public issuer URL (e.g. https://id.example.com). | `string` | n/a | yes |
| <a name="input_zitadel_org_id"></a> [zitadel\_org\_id](#input\_zitadel\_org\_id) | Zitadel org id the project + app live under. Caller resolves this at root via `data "zitadel_orgs" "platform_org"` and passes the value down — keeping the data source out of this module avoids the apply-time defer that consumer modules with `depends_on = [module.zitadel]` would otherwise hit and which cascades into `must be replaced` on every downstream resource. | `string` | n/a | yes |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | n/a | `string` | `"100m"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | n/a | `string` | `"10m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the auth gate. Should be tied to `services.zitadel.enabled` at the root — this module needs Zitadel as the OIDC provider. | `bool` | `false` | no |
| <a name="input_image"></a> [image](#input\_image) | Container image. Pinned tag so the OIDC config schema doesn't shift between restarts. | `string` | `"thomseddon/traefik-forward-auth:2.2.0"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | n/a | `string` | `"64Mi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | n/a | `string` | `"16Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the Deployment lives in. Expected to exist already (typically `ingress-controller`). | `string` | `null` | no |
| <a name="input_zitadel_provider_authenticated"></a> [zitadel\_provider\_authenticated](#input\_zitadel\_provider\_authenticated) | True when the root TF has been handed a non-empty `TF_VAR_zitadel_pat` for the Zitadel provider. False trips the precondition so the operator gets a clear error instead of an opaque provider 'unauthenticated' on apply. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_middleware_refs"></a> [middleware\_refs](#output\_middleware\_refs) | Ordered list of cross-namespace middleware refs an IngressRoute attaches under `spec.routes[].middlewares[]` for `auth: zitadel`. The order matters — `force-https-proto` rewrites `X-Forwarded-Proto: https` before the ForwardAuth sub-request fires, so traefik-forward-auth builds the correct `redirect_uri=https://auth...`. Null when the proxy is disabled (Zitadel off). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | n/a |
<!-- END_TF_DOCS -->
