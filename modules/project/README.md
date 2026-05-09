# project

Per-tenant project module: namespace + ResourceQuota + per-component DB/Redis/S3 credentials + chart-side YAML rendering for every component. The largest module in the platform — instantiated once per `config/domains/<domain>.yaml`.

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
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 1.19.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_chart_oidc"></a> [chart\_oidc](#module\_chart\_oidc) | ../zitadel-app | n/a |
| <a name="module_component"></a> [component](#module\_component) | ../component | n/a |
| <a name="module_zitadel_app"></a> [zitadel\_app](#module\_zitadel\_app) | ../zitadel-app | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.argocd_app_project](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.argocd_bootstrap](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.basic_auth_middleware](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.ingressroute](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_job_v1.mysql_setup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_job_v1.postgres_setup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_job_v1.redis_setup](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_resource_quota_v1.limits](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/resource_quota_v1) | resource |
| [kubernetes_secret_v1.basic_auth](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.db_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.env_random](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.ollama_endpoint](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.operator_secret](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.postgres_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.redis_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_password.basic_auth](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.db](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.env_random](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.operator_secret](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.postgres](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.redis](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_components"></a> [components](#input\_components) | Map of all available components from config/components/ | `any` | n/a | yes |
| <a name="input_default_limits"></a> [default\_limits](#input\_default\_limits) | Default resource quota limits | `any` | n/a | yes |
| <a name="input_project_config"></a> [project\_config](#input\_project\_config) | Expanded project/env entry from locals.projects | `any` | n/a | yes |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by hostPath PersistentVolumes for every component in this project. Must resolve to a real writable directory from the kubelet's point of view. Forwarded unchanged to modules/component. | `string` | n/a | yes |
| <a name="input_argocd_bootstraps"></a> [argocd\_bootstraps](#input\_argocd\_bootstraps) | Map of Argo CD bootstrap App-of-Apps roots declared under `envs.<env>.argocd_bootstraps:` in the domain yaml. Keyed by short name (engine emits `<namespace>-<key>-bootstrap` Application per entry). Each entry: `repo_url` (git remote URL — SSH form when `repo_ssh_key_id` is set), `path` (default `.`), `target_revision` (default `HEAD`), `repo_ssh_key_id` (optional — looked up in root `argocd_repo_ssh_keys` map). Sub-Applications under `path` are recursively synced by Argo CD; their `spec.project` must equal this project's namespace to clear the AppProject allowlist. AppProject `sourceRepos` aggregates every entry's `repo_url`, so sub-Applications cross-referencing peer repos pass the allowlist. Empty map disables Argo CD bootstrap (project still gets an AppProject when `argocd_hostnames` is non-empty). | `any` | `{}` | no |
| <a name="input_argocd_hostnames"></a> [argocd\_hostnames](#input\_argocd\_hostnames) | Map of Argo-managed hostnames declared under `envs.<env>.argocd_hostnames:` in the domain yaml. Keyed by host prefix (resolves to `<prefix>.<domain>`); value carries `cf_tunnel` (bool, default true — emit a Cloudflare Tunnel ingress rule routing the hostname through cloudflared → Traefik) and optional `node_ip` (string, required when `cf_tunnel = false` — TF emits an unproxied A record pointing at the node's real public IP, bypassing Cloudflare entirely). The IngressRoute itself for these hostnames is owned by the operator's deploy repo via Argo CD — TF only plumbs DNS + tunnel rule. Consumed by the root `cloudflare.tf` / `cloudflared.tf` for hostname registration. | `any` | `{}` | no |
| <a name="input_argocd_namespace"></a> [argocd\_namespace](#input\_argocd\_namespace) | Namespace where the Argo CD chart is installed. Argo CD AppProject + bootstrap Application CRDs land here when this project's domain yaml declares any `argocd_bootstraps:` entries. Empty disables Argo CD wiring entirely in this project (caller fails the precondition below if anything Argo-related is declared). | `string` | `""` | no |
| <a name="input_chart_oidc_apps"></a> [chart\_oidc\_apps](#input\_chart\_oidc\_apps) | Map of operator-named Secrets carrying engine-provisioned Zitadel OIDC client credentials. Keyed by Secret name (lands in the project namespace). Each entry: `app_name` (Zitadel Application display name), `redirect_uris` (list of allowed auth-code callback URLs), `post_logout_uris` (list, optional), `dev_mode` (bool, optional, allows http+localhost — flip on for dev pilots), `roles` (list of `{key, display_name, group?}` to register on the Zitadel Project). Engine creates one Zitadel Project + OIDC Application per entry through the existing `modules/zitadel-app`, and writes `AUTH_ZITADEL_ISSUER`, `AUTH_ZITADEL_ID`, `AUTH_ZITADEL_SECRET`, `AUTH_SECRET` into the Secret — same keys the Auth.js ecosystem expects. Use for chart-deployed apps that need OIDC without forcing the operator to register a client by hand. Empty map = no engine-managed chart OIDC. | `any` | `{}` | no |
| <a name="input_fallback_errors_middleware"></a> [fallback\_errors\_middleware](#input\_fallback\_errors\_middleware) | Cross-namespace Traefik `errors` Middleware ref appended to every IngressRoute's middleware chain. Replaces Traefik's default `no available server` body for 502/503/504 with the platform's branded fallback page when an IngressRoute's backend has zero ready endpoints (pod restart, deploy mid-roll, eviction). Null skips the wiring — useful when the fallback isn't deployed yet. | <pre>object({<br/>    name      = string<br/>    namespace = string<br/>  })</pre> | `null` | no |
| <a name="input_mysql_host"></a> [mysql\_host](#input\_mysql\_host) | In-cluster hostname of the shared MySQL; null when disabled. | `string` | `null` | no |
| <a name="input_mysql_namespace"></a> [mysql\_namespace](#input\_mysql\_namespace) | Namespace where the shared MySQL lives; null when `services.mysql = false`. | `string` | `null` | no |
| <a name="input_oauth2_proxy_middlewares"></a> [oauth2\_proxy\_middlewares](#input\_oauth2\_proxy\_middlewares) | Ordered list of cross-namespace Traefik Middleware refs (each `{name, namespace}`) the IngressRoute attaches under `spec.routes[].middlewares[]` for components with `auth: zitadel`. Order matters — the chain is applied head-first, so the `force-https-proto` headers middleware comes BEFORE the ForwardAuth so the latter sees the corrected `X-Forwarded-Proto`. Null when oauth2-proxy is disabled (Zitadel off). | <pre>list(object({<br/>    name      = string<br/>    namespace = string<br/>  }))</pre> | `null` | no |
| <a name="input_ollama_url"></a> [ollama\_url](#input\_ollama\_url) | In-cluster URL of the shared Ollama (e.g. http://ollama.platform.svc.cluster.local:11434). Injected as `OLLAMA_HOST` into any component that sets `ollama: true`. Null when `services.ollama = false`. | `string` | `null` | no |
| <a name="input_operator_secret_values"></a> [operator\_secret\_values](#input\_operator\_secret\_values) | Literal data values, keyed by `secrets:<name>`, for entries declared under `var.secrets`. Top-level key matches the Secret name; inner map carries `<data-key>` => `<literal value>`. Presence here switches the matching `var.secrets` entry into literal mode (random shared value path skipped). Plumbed unchanged from the root `var.operator_secret_values` — module filters per-project by entry name. Empty map = every project Secret stays in random-shared mode. | `map(map(string))` | `{}` | no |
| <a name="input_postgres_host"></a> [postgres\_host](#input\_postgres\_host) | In-cluster hostname of the shared PostgreSQL; null when disabled. | `string` | `null` | no |
| <a name="input_postgres_namespace"></a> [postgres\_namespace](#input\_postgres\_namespace) | Namespace where the shared PostgreSQL lives; null when `services.postgres = false`. | `string` | `null` | no |
| <a name="input_postgres_superuser_secret"></a> [postgres\_superuser\_secret](#input\_postgres\_superuser\_secret) | Name of the Secret (in `postgres_namespace`) holding the superuser password used by the tenant-provisioner Job; null when disabled. | `string` | `null` | no |
| <a name="input_redis_default_secret"></a> [redis\_default\_secret](#input\_redis\_default\_secret) | Name of the Secret (in `redis_namespace`) holding the default-user password used by the tenant-provisioner Job; null when disabled. | `string` | `null` | no |
| <a name="input_redis_helm_revision"></a> [redis\_helm\_revision](#input\_redis\_helm\_revision) | Helm release revision counter for the shared Redis chart. Interpolated into the tenant-provisioner Job's `metadata.name`, so any chart upgrade (revision bump) renames the Job and Terraform replaces it — re-running the ACL setup against whatever the post-upgrade master happens to be. Skipping this would leave tenants on stale ACL state after a master switch (the failure mode that produces `WRONGPASS` across every consumer). Zero / null when sentinel mode is disabled (legacy single-pod path uses a different bring-up Job). | `number` | `0` | no |
| <a name="input_redis_host"></a> [redis\_host](#input\_redis\_host) | In-cluster hostname of the shared Redis; null when disabled. | `string` | `null` | no |
| <a name="input_redis_namespace"></a> [redis\_namespace](#input\_redis\_namespace) | Namespace where the shared Redis lives; null when `services.redis = false`. | `string` | `null` | no |
| <a name="input_secrets"></a> [secrets](#input\_secrets) | Per-env `secrets:` map from the domain yaml — operator-defined Secrets emitted in the project namespace. Each entry: `keys` (list of data-key names), `length` (optional, default 48; ignored in literal mode). Two modes per entry, picked by whether the same name is also a key in `var.operator_secret_values`: (1) random-shared — every listed key receives the SAME random value, lets a chart's `envFrom` pull every variable from one Secret, fits app-key style use cases; (2) literal — engine reads values from `var.operator_secret_values[<name>]`, every yaml-listed key MUST be present there or plan-time check fails, fits operator-supplied credentials (third-party storage, OIDC client, vendor API keys) the engine cannot synthesize. Rotation: random mode → `tf taint random_password.<…>` + apply; literal mode → edit the value in `terraform.tfvars` + apply. | `any` | `{}` | no |
| <a name="input_shared_services"></a> [shared\_services](#input\_shared\_services) | Per-env `shared_services:` map from the domain yaml — flags telling the engine to provision per-namespace shared-service credentials (Postgres DB + role + Secret, Redis ACL user + Secret, Ollama Service URL Secret) WITHOUT requiring a `kind: deployment/app` component to opt in. Use for Argo CD-managed apps whose pods aren't TF-emitted but still need platform-shared backing services. Keys: `db` / `postgres` / `redis` / `ollama` (bool, default false). Provisioned credentials end up in standard Secret names the chart can consume via `envFrom` — `db-credentials`, `postgres-credentials`, `redis-credentials`, `ollama-endpoint`. | `any` | `{}` | no |
| <a name="input_zitadel_issuer_url"></a> [zitadel\_issuer\_url](#input\_zitadel\_issuer\_url) | Zitadel public issuer URL (https://id.<your-domain>) — embedded into AUTH\_ZITADEL\_ISSUER inside the per-app OIDC Secret. Null disables OIDC provisioning entirely (any kind: app component with `oidc.enabled: true` will fail with a clear error from the check below). | `string` | `null` | no |
| <a name="input_zitadel_org_id"></a> [zitadel\_org\_id](#input\_zitadel\_org\_id) | Zitadel org id where `kind: app` components auto-provision projects + applications. Caller resolves at root via `data "zitadel_orgs" "platform_org"` and passes the value down. Owning the data source at root rather than inside this module avoids the apply-time defer that propagates as `must be replaced` on every downstream resource whenever any consumer module declares `depends_on = [module.zitadel]`. | `string` | `""` | no |
| <a name="input_zitadel_provider_authenticated"></a> [zitadel\_provider\_authenticated](#input\_zitadel\_provider\_authenticated) | True when the root TF has been handed a non-empty `TF_VAR_zitadel_pat` for the Zitadel provider. False trips the precondition on any active `kind: app` + `oidc.enabled: true` component, with a pointer at the operator-side bootstrap docs. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_argocd_hostnames"></a> [argocd\_hostnames](#output\_argocd\_hostnames) | Argo CD-managed hostnames for this project. Resolved per-prefix against the project's domain. Each entry carries the cf\_tunnel toggle + (when toggle is false) the node\_ip the operator wants the A record pointing at. Consumed by the root `cloudflare.tf` to emit either a tunnel-routed CNAME + ingress rule (cf\_tunnel=true) or an unproxied A record bypassing CF entirely (cf\_tunnel=false). |
| <a name="output_basic_auth_credentials"></a> [basic\_auth\_credentials](#output\_basic\_auth\_credentials) | HTTP BasicAuth credentials generated for every component in this project whose spec sets `basic_auth: true`. Keyed by component name; value is `{user, password}` in plaintext. Retrieve with: terraform output -json basic\_auth\_credentials \| jq |
| <a name="output_components"></a> [components](#output\_components) | n/a |
| <a name="output_domain"></a> [domain](#output\_domain) | n/a |
| <a name="output_env"></a> [env](#output\_env) | n/a |
| <a name="output_has_db"></a> [has\_db](#output\_has\_db) | n/a |
| <a name="output_hostnames"></a> [hostnames](#output\_hostnames) | Every fully-qualified hostname → which component/service it routes to. Consumed by the root `cloudflare.tf` to build the Cloudflare tunnel ingress rules and the per-host CNAME DNS records.  `http2_origin` propagates from the component yaml (`http2_origin: true`) to the cloudflared route's `origin_request.http2_origin`, which is what flips cloudflared from HTTP/1.1 to HTTP/2 upstream — required end-to-end for any service that exposes gRPC alongside HTTP (Zitadel). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
<!-- END_TF_DOCS -->
