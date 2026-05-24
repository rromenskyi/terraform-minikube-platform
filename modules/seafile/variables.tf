variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context. Default `null` means no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to install Seafile. False collapses every resource to zero — namespace, Deployment, Service, IngressRoute, PVC, MySQL setup Job."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the Seafile pod + supporting resources land in. Module owns creation; name must not collide with one already managed elsewhere. Convention is `seafile`."
  type        = string
  default     = "seafile"
}

variable "image_tag" {
  description = "Tag of the upstream `seafileltd/seafile-mc` image. Pin to a known-good CE release (currently 13.0.x line); bump deliberately when upstream cuts a minor or major. The `-mc` variant ships memcached, but Seafile 13 defaults to Redis for cache (configured via env)."
  type        = string
  default     = "13.0.21"
}

variable "external_hostname" {
  description = "Public hostname Seahub serves at (e.g. `cloud.example.com`). Used in `SERVICE_URL`, `FILE_SERVER_ROOT`, OAuth redirect URI, CSRF trusted origin, and the IngressRoute Host matcher. Operator picks; engine emits no DNS record (DNS lives in domain yaml's `argocd_hostnames` or equivalent)."
  type        = string
}

variable "admin_email" {
  description = "Email address of the bootstrap super-user account Seafile creates on first boot. Used together with the random-generated `INIT_SEAFILE_ADMIN_PASSWORD`. After first boot the password is baked into the Seafile DB and rotation goes through Seahub UI; the env var is ignored on subsequent restarts. Set to the operator's primary email."
  type        = string
}

variable "mysql_host" {
  description = "Hostname/IP of the shared MySQL instance the engine pre-creates Seafile databases on (`ccnet_db`, `seafile_db`, `seahub_db`). Convention: `mysql.platform.svc.cluster.local`."
  type        = string
}

variable "mysql_port" {
  description = "Port of the shared MySQL instance. Default 3306."
  type        = number
  default     = 3306
}

variable "mysql_root_password" {
  description = "Sensitive — root password for the shared MySQL instance. Used by the one-shot setup Job to CREATE DATABASE + GRANT to the scoped `seafile` user. NOT embedded in the running pod's bootstrap Secret beyond first-boot init (Seafile's bootstrap script needs it once to lay down the schema; subsequent restarts only use the scoped user)."
  type        = string
  sensitive   = true
}

variable "redis_host" {
  description = "Hostname of the shared Redis instance Seafile uses as cache backend (Seafile 13 default). Convention: `redis.platform.svc.cluster.local`. Auth-less because the cluster is the trust boundary."
  type        = string
}

variable "redis_port" {
  description = "Port of the shared Redis instance. Default 6379."
  type        = number
  default     = 6379
}

variable "redis_password" {
  description = "Sensitive — password for the `default` Redis user. Seafile 13 doesn't get its own scoped ACL user (no per-app provisioner Job at engine-level for Seafile), so it uses the default user with full access. Caller wires from `module.redis.default_password`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "storage_class" {
  description = "StorageClass used for the `/shared` PVC carrying Seafile's library blocks, ccnet state, conf, and logs. Convention is `longhorn` so the volume survives node loss. Empty string falls back to the cluster's default StorageClass."
  type        = string
  default     = "longhorn"
}

variable "storage_size" {
  description = "Capacity request on the `/shared` PVC. Sized as ~1.2× expected raw file storage (block dedup + version history overhead). Start small and resize through Longhorn UI / kubectl edit pvc; Stalwart-style upfront over-provisioning isn't useful here."
  type        = string
  default     = "100Gi"
}

variable "oidc_issuer_url" {
  description = "Zitadel issuer URL (e.g. `https://id.example.com`). When non-empty and `oidc_client_id` is also set, Seahub OAuth/OIDC integration is rendered into seahub_settings.py. Empty disables OIDC; operator falls back to Seafile's local password auth via the bootstrap admin."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client_id Seahub presents to Zitadel during the auth-code flow. Caller wires from `module.<service>_oidc.client_id`."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "Sensitive — OIDC client_secret Seahub uses for the back-channel token exchange. Caller wires from `module.<service>_oidc.client_secret`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "timezone" {
  description = "TZ database name Seafile uses for log timestamps and scheduled tasks. Default `Etc/UTC`."
  type        = string
  default     = "Etc/UTC"
}

variable "cpu_request" {
  description = "Container `resources.requests.cpu` for the Seafile pod. Idle Seahub + ccnet + fileserver sit around 100m; Seafile's Django startup briefly spikes to 1+ cpu."
  type        = string
  default     = "200m"
}

variable "cpu_limit" {
  description = "Container `resources.limits.cpu`. Cap a runaway sync storm or large library indexing burst from starving the node."
  type        = string
  default     = "2"
}

variable "memory_request" {
  description = "Container `resources.requests.memory`. Seahub's Django + gunicorn process count drives baseline; ~512Mi is comfortable for a single operator."
  type        = string
  default     = "512Mi"
}

variable "memory_limit" {
  description = "Container `resources.limits.memory`. Bumps to 2Gi during library scan / search index rebuilds."
  type        = string
  default     = "2Gi"
}

variable "node_selector" {
  description = "Node selector pinning Seafile to a specific node tier. Empty = scheduler picks. PVC ReadWriteOnce constrains scheduling to nodes that can mount the Longhorn volume; for hostPath-style storage classes pin explicitly."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Pod tolerations for tainted nodes."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}
