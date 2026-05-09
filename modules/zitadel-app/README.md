# zitadel-app

Per-application Zitadel project + OIDC application + Kubernetes Secret with AUTH_ZITADEL_* env. Instantiated once per protected component (Stalwart, Roundcube, Vault, Argo CD, platform-dash, …).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
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
| [kubernetes_secret_v1.oidc](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_password.auth_secret](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [zitadel_application_oidc.this](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/application_oidc) | resource |
| [zitadel_project.this](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project) | resource |
| [zitadel_project_role.roles](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project_role) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_app_name"></a> [app\_name](#input\_app\_name) | Zitadel Application name. Component name is the natural pick. | `string` | n/a | yes |
| <a name="input_issuer_url"></a> [issuer\_url](#input\_issuer\_url) | Zitadel public issuer URL (e.g. https://id.example.com). Embedded into the AUTH\_ZITADEL\_ISSUER env var so client apps don't have to repeat it. | `string` | n/a | yes |
| <a name="input_org_id"></a> [org\_id](#input\_org\_id) | Zitadel org id the project + app live under. Caller resolves at root via `data "zitadel_orgs" "platform_org"` and passes the value down. Owning the data source at root rather than inside this module avoids the apply-time defer that propagates as `must be replaced` on every downstream resource whenever any consumer module declares `depends_on = [module.zitadel]`. | `string` | n/a | yes |
| <a name="input_project_name"></a> [project\_name](#input\_project\_name) | Zitadel Project name. v1 limitation: one project per app (every `kind: app` component gets its own project, named after the app). Sharing a project across apps is a follow-up — would need project creation hoisted out of this per-app module. | `string` | n/a | yes |
| <a name="input_secret_name"></a> [secret\_name](#input\_secret\_name) | Name of the Secret to create. | `string` | n/a | yes |
| <a name="input_secret_namespace"></a> [secret\_namespace](#input\_secret\_namespace) | K8s namespace where the Secret holding AUTH\_ZITADEL\_* + AUTH\_SECRET lands. | `string` | n/a | yes |
| <a name="input_app_type"></a> [app\_type](#input\_app\_type) | Zitadel app type — WEB (server-side, has client\_secret), USER\_AGENT (SPA, PKCE), NATIVE (mobile, PKCE). | `string` | `"OIDC_APP_TYPE_WEB"` | no |
| <a name="input_auth_method"></a> [auth\_method](#input\_auth\_method) | Client auth method when redeeming auth codes. BASIC = client\_id:client\_secret in Authorization header. NONE = PKCE only (use for SPA/native). | `string` | `"OIDC_AUTH_METHOD_TYPE_BASIC"` | no |
| <a name="input_dev_mode"></a> [dev\_mode](#input\_dev\_mode) | Allow `http://` and `localhost` redirect URIs. Off by default (production-style strict). Flip on while iterating locally. | `bool` | `false` | no |
| <a name="input_grant_types"></a> [grant\_types](#input\_grant\_types) | OIDC grant types. Default = Authorization Code + Refresh Token, the standard combo for SSR web apps. | `list(string)` | <pre>[<br/>  "OIDC_GRANT_TYPE_AUTHORIZATION_CODE",<br/>  "OIDC_GRANT_TYPE_REFRESH_TOKEN"<br/>]</pre> | no |
| <a name="input_post_logout_uris"></a> [post\_logout\_uris](#input\_post\_logout\_uris) | URLs Zitadel will allow as post-logout redirect destinations. Built upstream from component hostnames + `oidc.post_logout_paths`. | `list(string)` | `[]` | no |
| <a name="input_redirect_uris"></a> [redirect\_uris](#input\_redirect\_uris) | Full URLs Zitadel will allow as auth-code callback destinations. Built upstream from component hostnames + `oidc.redirect_paths` (e.g. `["https://app.example.com/auth/callback/zitadel"]`). | `list(string)` | `[]` | no |
| <a name="input_response_types"></a> [response\_types](#input\_response\_types) | OIDC response types. Default = Authorization Code flow only. | `list(string)` | <pre>[<br/>  "OIDC_RESPONSE_TYPE_CODE"<br/>]</pre> | no |
| <a name="input_roles"></a> [roles](#input\_roles) | Project roles to create — each becomes a Zitadel role grantable to users (platform\_admin, tenant\_admin, user, etc). The role keys land in the user's OIDC token under `urn:zitadel:iam:org:project:roles` and downstream apps gate features on them. | <pre>list(object({<br/>    key          = string<br/>    display_name = string<br/>    group        = optional(string, "")<br/>  }))</pre> | `[]` | no |
| <a name="input_secret_formats"></a> [secret\_formats](#input\_secret\_formats) | List of env-name conventions to materialise inside the emitted Secret. Each format adds a parallel set of keys with the same client\_id / client\_secret / issuer values rendered under the env names that format expects. Multiple formats stack non-destructively — a chart that reads any one of them works without engine changes. Supported values: `auth_js` (default — emits AUTH\_ZITADEL\_ISSUER / AUTH\_ZITADEL\_ID / AUTH\_ZITADEL\_SECRET / AUTH\_SECRET, the @auth/sveltekit + Auth.js convention), `open_webui` (OAUTH\_CLIENT\_ID / OAUTH\_CLIENT\_SECRET / OPENID\_PROVIDER\_URL — Open WebUI's `ENABLE_OAUTH_SIGNUP` path), `grafana_oauth` (GF\_AUTH\_GENERIC\_OAUTH\_CLIENT\_ID / GF\_AUTH\_GENERIC\_OAUTH\_CLIENT\_SECRET / GF\_AUTH\_GENERIC\_OAUTH\_AUTH\_URL / \_TOKEN\_URL / \_API\_URL — Grafana's generic OAuth provider). Empty list disables every format (Secret still created but data-only — engine consumers can read raw `*` outputs). | `list(string)` | <pre>[<br/>  "auth_js"<br/>]</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_app_id"></a> [app\_id](#output\_app\_id) | n/a |
| <a name="output_client_id"></a> [client\_id](#output\_client\_id) | n/a |
| <a name="output_client_secret"></a> [client\_secret](#output\_client\_secret) | Generated client secret for the OIDC application. Consumed directly when the downstream module renders Helm values that need the secret inline (e.g. Argo CD's Dex connector). Most kind:app components mount the AUTH\_ZITADEL\_SECRET key from the emitted k8s Secret instead — this output is for the rare case where Helm-time interpolation is needed. |
| <a name="output_project_id"></a> [project\_id](#output\_project\_id) | n/a |
| <a name="output_secret_checksum"></a> [secret\_checksum](#output\_secret\_checksum) | SHA1 of the OIDC Secret's data, surfaced for use as a pod-template `checksum/oidc` annotation. Drives a Deployment rollout when the Zitadel app is recreated (e.g. after `terraform destroy`+`apply`, or after a manual app rotation in Zitadel) so the pod picks up the new client\_id/client\_secret instead of carrying the stale env from its previous start. The hash itself reveals nothing — `nonsensitive()` is used to drop the sensitivity bit so the annotation is renderable. |
| <a name="output_secret_name"></a> [secret\_name](#output\_secret\_name) | Name of the Secret holding AUTH\_ZITADEL\_ISSUER, AUTH\_ZITADEL\_ID, AUTH\_ZITADEL\_SECRET, AUTH\_SECRET — feed into the component as `oidc_secret_name`. |
<!-- END_TF_DOCS -->
