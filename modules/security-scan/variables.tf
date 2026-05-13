variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context (still works, just doesn't carry the platform-tier tags)."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to install trivy-operator + the snapshot CronJob. False collapses every resource to zero — namespace, helm release, PV/PVC, RBAC, CronJob, Vault Secret all disappear."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the trivy-operator deployment + snapshot CronJob land in. Module owns the namespace creation, so the name must not collide with one already managed elsewhere. Convention is `security-scan` — a sibling of the other platform-system namespaces (`vault`, `zitadel`, etc.)."
  type        = string
  default     = "security-scan"
}

variable "trivy_operator_chart_version" {
  description = "Version of the upstream `trivy-operator` Helm chart (https://github.com/aquasecurity/trivy-operator). Pin to a known-good release; bump deliberately when upstream cuts a security fix or major version. Chart repo: https://aquasecurity.github.io/helm-charts/ ."
  type        = string
  default     = "0.30.0"
}

variable "host_volume_path" {
  description = "Parent path used by the trivy DB cache hostPath PV. Same convention as the rest of the engine (`var.host_volume_path` on the root) — module appends `/trivy-cache` to derive the on-disk dir. The kubelet on `var.cache_node_hostname` must be able to read/write this path."
  type        = string
  default     = "/data/vol"
}

variable "cache_node_hostname" {
  description = "Hostname (`kubernetes.io/hostname`) of the node the trivy DB cache PV pins to. Should match the operator's `stateful` tier node — that's the convention for hostPath PVs. Without an explicit pin the PV could bind on a node where the hostPath dir doesn't exist."
  type        = string
  default     = "roman-romenskyi-optiplex-7060"
}

variable "trivy_cache_size" {
  description = "Capacity declared on the trivy DB cache PV/PVC. Trivy's vulnerability DB is ~700 MB compressed; allow headroom for repo metadata and parallel scan working space. Plain `1Gi` is too tight if upstream DB grows; 5Gi gives years of runway."
  type        = string
  default     = "5Gi"
}

variable "service_monitor_enabled" {
  description = "Whether to emit a `ServiceMonitor` for trivy-operator's metrics endpoint, scraped by the platform's kube-prometheus-stack. False if the platform doesn't run kube-prometheus-stack — ServiceMonitor CRD must exist or the helm install fails on schema validation."
  type        = bool
  default     = false
}

variable "snapshot_schedule" {
  description = "Cron expression for the weekly snapshot CronJob. Default is Sunday 04:00 UTC — quiet time, plenty of CI headroom, and weekly cadence keeps PR noise low for a single operator. Bump to daily (`0 4 * * *`) if signal proves valuable."
  type        = string
  default     = "0 4 * * 0"
}

variable "github_repo" {
  description = "Full `owner/repo` slug of the platform engine repo where the snapshot CronJob commits the CVE report and opens a PR. Format: `<owner>/<repo>` (no scheme, no `.git` suffix). The PAT in Vault under `secret/data/platform/github-deploy-tokens/security-scan` must hold `repo` (full) scope on this repo."
  type        = string
  default     = "rromenskyi/terraform-minikube-platform"
}

variable "branch_prefix" {
  description = "Prefix the CronJob uses when creating PR branches — e.g. `security-scan/2026-05-19`. The date suffix is generated at run time. The branch is force-pushed each run, so multiple in the same week share one branch (PRs auto-update rather than spawning new ones). Leave defaulted unless the operator wants a different naming convention."
  type        = string
  default     = "security-scan/snapshot"
}

variable "telegram_notify_enabled" {
  description = "Whether to DM the operator on Telegram when the snapshot content changed since last run. Requires the operator to have placed a bot's `bot_token` + numeric `chat_id` at `var.telegram_vault_path` in Vault. False (default) skips the VaultStaticSecret + the env wiring entirely; the CronJob runs without notification — PR open is the only signal."
  type        = bool
  default     = false
}

variable "telegram_vault_path" {
  description = "Vault path (under `secret/data/...`, kv-v2 mount) holding the Telegram bot creds for snapshot notifications. Expected data keys: `bot_token` (the `<id>:<auth>` string from BotFather) and `chat_id` (numeric int — Bot API doesn't accept usernames for DMs, only channel `@names` or numeric chat IDs). Default path lives under `platform/telegram-bots/operator` to leave room for additional bots later. Has no effect when `var.telegram_notify_enabled = false`."
  type        = string
  default     = "platform/telegram-bots/operator"
}
