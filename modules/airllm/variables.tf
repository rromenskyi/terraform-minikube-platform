variable "enabled" {
  description = "Whether to install this AirLLM instance. False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "name" {
  description = "Instance name. It names the Argo CD Application (and so the Helm release and the chart's Service), the runtime Secret (`<name>-secrets`), the Redis ACL user, the Postgres setup Job and the TLS and routing objects. Keep `airllm` in it: the chart then uses it as is for its resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name)) && strcontains(var.name, "airllm")
    error_message = "name must be a DNS label (lowercase letters, digits, '-') that contains `airllm`."
  }
}

variable "namespace" {
  description = "Namespace the gateway runs in. The module creates it."
  type        = string
}

variable "tags" {
  description = "Labels put on every object the module creates (the platform tier labels from the caller)."
  type        = map(string)
  default     = {}
}

variable "app_env" {
  description = "The app's `ENV` (`config.env`): `prod` or `dev`. It is also the tag in newly issued API keys (`air_<env>_...`)."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["prod", "dev"], var.app_env)
    error_message = "app_env must be `prod` or `dev`."
  }
}

# ── Chart source ────────────────────────────────────────────────────────────

variable "repo_url" {
  description = "Git repository with the public chart (`deploy/helm/airllm`)."
  type        = string
  default     = "https://github.com/ipsupport-llc/ipsupport-airllm.git"
}

variable "chart_revision" {
  description = "Git revision Argo CD tracks. `main` = continuous: Argo CD also reads `deploy/argocd/values-main.yaml`, the image digests the app repo's CI commits after every green build, so a merge there is the rollout. A release tag (`vX.Y.Z`) pins that release: values-main.yaml is left out and an empty `image_tag` follows the tag's appVersion."
  type        = string
  default     = "main"
}

variable "image_tag" {
  description = "Image tag for the gateway and the DLP model server. Empty = the chart's appVersion (or the digests from values-main.yaml on `main`)."
  type        = string
  default     = ""
}

# ── Workload ────────────────────────────────────────────────────────────────

variable "replicas" {
  description = "Gateway replicas. Provider concurrency caps and round-robin counters are per replica: with N replicas a provider's `max_concurrency` admits N times that many requests in total."
  type        = number
  default     = 2
}

variable "node_selector" {
  description = "Node selector for the gateway pods. Empty lets them land on any node."
  type        = map(string)
  default     = {}
}

variable "dashboards_enabled" {
  description = "Ship the chart's Grafana dashboards. Their uids are fixed, so only one instance per Grafana may have them on."
  type        = bool
  default     = true
}

variable "prometheus_rule_enabled" {
  description = "Ship the chart's tier-quarantine alert."
  type        = bool
  default     = true
}

# ── Platform services the gateway uses ─────────────────────────────────────

variable "argocd_namespace" {
  description = "Namespace of Argo CD; the Application lands there under the `platform` AppProject."
  type        = string
}

variable "setup_namespace" {
  description = "Namespace for the database setup Jobs. It must hold `postgres_superuser_secret`."
  type        = string
}

variable "postgres_host" {
  description = "Shared Postgres host."
  type        = string
}

variable "postgres_superuser_secret" {
  description = "Secret in `setup_namespace` with the Postgres superuser password under `POSTGRES_PASSWORD`."
  type        = string
}

variable "database_name" {
  description = "Database and role the instance owns on the shared Postgres. Created by the setup Job."
  type        = string

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]*$", var.database_name))
    error_message = "database_name must be a lowercase SQL identifier (letters, digits, '_')."
  }
}

variable "seed_from_database" {
  description = "Database to copy into `database_name` once, when it is still empty (no tables). Empty = start from an empty database. The copy holds provider credentials encrypted with the source instance's master key, so set `master_key` to that key as well."
  type        = string
  default     = ""
}

variable "redis_host" {
  description = "Shared Redis host."
  type        = string
}

variable "redis_port" {
  description = "Shared Redis port."
  type        = number
}

variable "redis_db" {
  description = "Redis database index. The app's keys all start with `air:`, so two instances on one Redis need different indexes or they share usage counters, locks and breaker state."
  type        = number
  default     = 0
}

variable "redis_acl_namespace" {
  description = "Namespace the Redis ACL keeper reads `platform.local/redis-acl` Secrets from (see modules/redis)."
  type        = string
}

variable "master_key" {
  description = "Base64 master key the app encrypts provider credentials with. Empty = generate one. Set it to another instance's key only together with `seed_from_database`, so the copied credentials still decrypt."
  type        = string
  default     = ""
  sensitive   = true
}

# ── Login ───────────────────────────────────────────────────────────────────

variable "oidc" {
  description = "OIDC login (`authMode: oidc`). Null = local accounts (`authMode: local`, bootstrap admin `admin`). In OIDC mode the app has no password login. `redirect_url` is `https://<hostname>/auth/callback`. `roles_claim` is the claim holding the user's roles (a string array or an object keyed by role); `role_map` maps those to `airllm_admin` / `airllm_user` as `idp_role:airllm_role,...`; a role not in the map grants nothing."
  type = object({
    issuer      = string
    client_id   = string
    roles_claim = string
    role_map    = string
  })
  default = null
}

variable "oidc_client_secret" {
  description = "Client secret of the OIDC application; required with `oidc`. Stored in the runtime Secret as `oidc-client-secret`."
  type        = string
  default     = ""
  sensitive   = true
}

# ── GCP Workload Identity Federation ────────────────────────────────────────

variable "google_service_account" {
  description = "GCP service account the pod impersonates for the gateway's `vertex` provider kind. Empty leaves the chart's block off. The SA must allow `workloadIdentityUser` for `system:serviceaccount:<namespace>:<name>`."
  type        = string
  default     = ""
}

variable "gcp_wif_audience" {
  description = "The cluster's WIF provider audience, `//iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>`. Required when `google_service_account` is set."
  type        = string
  default     = ""
}

# ── Exposure ────────────────────────────────────────────────────────────────

variable "hostname" {
  description = "Public hostname. Empty = no certificate, routes or DNS record (in-cluster only)."
  type        = string
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone for the unproxied A record. Empty = no record."
  type        = string
  default     = ""
}

variable "public_ip" {
  description = "Address the A record points at (the public Traefik VIP)."
  type        = string
  default     = ""
}
