variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own `project_label` off the platform-wide context — tags propagate down, ids stay under per-feature explicit control. Default `null` means the project module produces a label with no inherited context (still works, just doesn't carry the platform-tier tags)."
  type        = string
  default     = null
}

variable "project_config" {
  description = "Expanded project/env entry from locals.projects"
  type        = any
}

variable "git_deploy_keys" {
  description = "Per-project git-sync deploy keys, declared in domain yaml under the env's `git_deploy_keys:` block as `{<id>: {host: github.com}}` (host optional, default github.com). Engine emits one `VaultStaticSecret` per entry pointing at `secret/data/tenants/<slug>/git-deploy-keys/<id>`; VSO syncs into a `kubernetes.io/ssh-auth` Secret named `git-deploy-key-<id>` in the project namespace, combining the operator-supplied `sshPrivateKey` from Vault with the engine-known `known_hosts` line for `<host>`. Tenant authenticates against Vault via Zitadel SSO (role `tenant_<slug>`) and writes the key under the conventional path themselves — operator out of the loop after the initial Zitadel role grant."
  type        = map(any)
  default     = {}
}

variable "components" {
  description = "Map of all available components from config/components/"
  type        = any
}

variable "default_limits" {
  description = "Default resource quota limits"
  type        = any
}

variable "mysql_namespace" {
  description = "Namespace where the shared MySQL lives; null when `services.mysql = false`."
  type        = string
  default     = null
}

variable "mysql_host" {
  description = "In-cluster hostname of the shared MySQL; null when disabled."
  type        = string
  default     = null
}

variable "postgres_namespace" {
  description = "Namespace where the shared PostgreSQL lives; null when `services.postgres = false`."
  type        = string
  default     = null
}

variable "postgres_host" {
  description = "In-cluster hostname of the shared PostgreSQL; null when disabled."
  type        = string
  default     = null
}

variable "postgres_superuser_secret" {
  description = "Name of the Secret (in `postgres_namespace`) holding the superuser password used by the tenant-provisioner Job; null when disabled."
  type        = string
  default     = null
}

variable "redis_namespace" {
  description = "Namespace where the shared Redis lives; null when `services.redis = false`."
  type        = string
  default     = null
}

variable "redis_host" {
  description = "In-cluster hostname of the shared Redis; null when disabled."
  type        = string
  default     = null
}

variable "redis_default_secret" {
  description = "Name of the Secret (in `redis_namespace`) holding the default-user password used by the tenant-provisioner Job; null when disabled."
  type        = string
  default     = null
}

variable "redis_helm_revision" {
  description = "Helm release revision counter for the shared Redis chart. Interpolated into the tenant-provisioner Job's `metadata.name`, so any chart upgrade (revision bump) renames the Job and Terraform replaces it — re-running the ACL setup against whatever the post-upgrade master happens to be. Skipping this would leave tenants on stale ACL state after a master switch (the failure mode that produces `WRONGPASS` across every consumer). Zero / null when sentinel mode is disabled (legacy single-pod path uses a different bring-up Job)."
  type        = number
  default     = 0
}

variable "ollama_url" {
  description = "In-cluster URL of the shared Ollama (e.g. http://ollama.platform.svc.cluster.local:11434). Injected as `OLLAMA_HOST` into any component that sets `ollama: true`. Null when `services.ollama = false`."
  type        = string
  default     = null
}

variable "gcp_wif_pool_provider_audience" {
  description = "Cluster-wide WIF audience (`//iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>`) used in both the projected SA token's `aud` claim AND in the rendered `credential-config.json` for every component opted into GCP Workload Identity Federation via `gcp_wif.gcp_service_account` on its component yaml. Empty string disables WIF wiring; component-level opt-in then fails a plan-time check. Sourced from `services.gcp_wif.pool_provider_audience` at the root."
  type        = string
  default     = ""
}

variable "zitadel_org_id" {
  description = "Zitadel org id where `kind: app` components auto-provision projects + applications. Caller resolves at root via `data \"zitadel_orgs\" \"platform_org\"` and passes the value down. Owning the data source at root rather than inside this module avoids the apply-time defer that propagates as `must be replaced` on every downstream resource whenever any consumer module declares `depends_on = [module.zitadel]`."
  type        = string
  default     = ""
}

variable "zitadel_issuer_url" {
  description = "Zitadel public issuer URL (https://id.<your-domain>) — embedded into AUTH_ZITADEL_ISSUER inside the per-app OIDC Secret. Null disables OIDC provisioning entirely (any kind: app component with `oidc.enabled: true` will fail with a clear error from the check below)."
  type        = string
  default     = null
}

variable "zitadel_provider_authenticated" {
  description = "True when the root TF has been handed a non-empty `TF_VAR_zitadel_pat` for the Zitadel provider. False trips the precondition on any active `kind: app` + `oidc.enabled: true` component, with a pointer at the operator-side bootstrap docs."
  type        = bool
  default     = false
}

variable "oauth2_proxy_middlewares" {
  description = "Ordered list of cross-namespace Traefik Middleware refs (each `{name, namespace}`) the IngressRoute attaches under `spec.routes[].middlewares[]` for components with `auth: zitadel`. Order matters — the chain is applied head-first, so the `force-https-proto` headers middleware comes BEFORE the ForwardAuth so the latter sees the corrected `X-Forwarded-Proto`. Null when oauth2-proxy is disabled (Zitadel off)."
  type = list(object({
    name      = string
    namespace = string
  }))
  default = null
}

variable "fallback_errors_middleware" {
  description = "Cross-namespace Traefik `errors` Middleware ref appended to every IngressRoute's middleware chain. Replaces Traefik's default `no available server` body for 502/503/504 with the platform's branded fallback page when an IngressRoute's backend has zero ready endpoints (pod restart, deploy mid-roll, eviction). Null skips the wiring — useful when the fallback isn't deployed yet."
  type = object({
    name      = string
    namespace = string
  })
  default = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by hostPath PersistentVolumes for every component in this project. Must resolve to a real writable directory from the kubelet's point of view. Forwarded unchanged to modules/component."
  type        = string
}

variable "argocd_namespace" {
  description = "Namespace where the Argo CD chart is installed. Argo CD AppProject + bootstrap Application CRDs land here when this project's domain yaml declares any `argocd_bootstraps:` entries. Empty disables Argo CD wiring entirely in this project (caller fails the precondition below if anything Argo-related is declared)."
  type        = string
  default     = ""
}

variable "argocd_hostnames" {
  description = "Map of Argo-managed hostnames declared under `envs.<env>.argocd_hostnames:` in the domain yaml. Keyed by host prefix (resolves to `<prefix>.<domain>`); value carries `cf_tunnel` (bool, default true — emit a Cloudflare Tunnel ingress rule routing the hostname through cloudflared → Traefik) and optional `node_ip` (string, required when `cf_tunnel = false` — TF emits an unproxied A record pointing at the node's real public IP, bypassing Cloudflare entirely). The IngressRoute itself for these hostnames is owned by the operator's deploy repo via Argo CD — TF only plumbs DNS + tunnel rule. Consumed by the root `cloudflare.tf` / `cloudflared.tf` for hostname registration."
  type        = any
  default     = {}
}

variable "argocd_bootstraps" {
  description = "Map of Argo CD bootstrap App-of-Apps roots declared under `envs.<env>.argocd_bootstraps:` in the domain yaml. Keyed by short name (engine emits `<namespace>-<key>-bootstrap` Application per entry). Each entry: `repo_url` (git remote URL — SSH form when `repo_ssh_key_id` is set), `path` (default `.`), `target_revision` (default `HEAD`), `repo_ssh_key_id` (optional — looked up in root `argocd_repo_ssh_keys` map). Sub-Applications under `path` are recursively synced by Argo CD; their `spec.project` must equal this project's namespace to clear the AppProject allowlist. AppProject `sourceRepos` aggregates every entry's `repo_url`, so sub-Applications cross-referencing peer repos pass the allowlist. Empty map disables Argo CD bootstrap (project still gets an AppProject when `argocd_hostnames` is non-empty)."
  type        = any
  default     = {}
}

variable "shared_services" {
  description = "Per-env `shared_services:` map from the domain yaml — flags telling the engine to provision per-namespace shared-service credentials (Postgres DB + role + Secret, Redis ACL user + Secret, Ollama Service URL Secret) WITHOUT requiring a `kind: deployment/app` component to opt in. Use for Argo CD-managed apps whose pods aren't TF-emitted but still need platform-shared backing services. Keys: `db` / `postgres` / `redis` / `ollama` (bool, default false). Provisioned credentials end up in standard Secret names the chart can consume via `envFrom` — `db-credentials`, `postgres-credentials`, `redis-credentials`, `ollama-endpoint`."
  type        = any
  default     = {}
}

variable "secrets" {
  description = "Per-env `secrets:` map from the domain yaml — operator-defined Secrets emitted in the project namespace. Each entry: `keys` (list of data-key names), `length` (optional, default 48; ignored in literal mode). Two modes per entry, picked by whether the same name is also a key in `var.operator_secret_values`: (1) random-shared — every listed key receives the SAME random value, lets a chart's `envFrom` pull every variable from one Secret, fits app-key style use cases; (2) literal — engine reads values from `var.operator_secret_values[<name>]`, every yaml-listed key MUST be present there or plan-time check fails, fits operator-supplied credentials (third-party storage, OIDC client, vendor API keys) the engine cannot synthesize. Rotation: random mode → `tf taint random_password.<…>` + apply; literal mode → edit the value in `terraform.tfvars` + apply."
  type        = any
  default     = {}
}

variable "operator_secret_values" {
  description = "Literal data values, keyed by `secrets:<name>`, for entries declared under `var.secrets`. Top-level key matches the Secret name; inner map carries `<data-key>` => `<literal value>`. Presence here switches the matching `var.secrets` entry into literal mode (random shared value path skipped). Plumbed unchanged from the root `var.operator_secret_values` — module filters per-project by entry name. Empty map = every project Secret stays in random-shared mode."
  type        = map(map(string))
  default     = {}
  sensitive   = true
}

variable "chart_oidc_apps" {
  description = "Map of operator-named Secrets carrying engine-provisioned Zitadel OIDC client credentials. Keyed by Secret name (lands in the project namespace). Each entry: `app_name` (Zitadel Application display name), `redirect_uris` (list of allowed auth-code callback URLs), `post_logout_uris` (list, optional), `dev_mode` (bool, optional, allows http+localhost — flip on for dev pilots), `roles` (list of `{key, display_name, group?}` to register on the Zitadel Project). Engine creates one Zitadel Project + OIDC Application per entry through the existing `modules/zitadel-app`, and writes `AUTH_ZITADEL_ISSUER`, `AUTH_ZITADEL_ID`, `AUTH_ZITADEL_SECRET`, `AUTH_SECRET` into the Secret — same keys the Auth.js ecosystem expects. Use for chart-deployed apps that need OIDC without forcing the operator to register a client by hand. Empty map = no engine-managed chart OIDC."
  type        = any
  default     = {}
}
