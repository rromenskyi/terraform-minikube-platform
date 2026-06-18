variable "enabled" {
  description = "Whether to deploy Argo CD. False collapses every resource — single-node clusters that don't need GitOps stay clean."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Argo CD lives in. Created by the chart's `create_namespace = true` so the operator doesn't have to declare it elsewhere."
  type        = string
  default     = "argocd"
}

variable "version_pin" {
  description = "Helm chart version for argo/argo-cd. Pinned so an upstream re-tag doesn't silently change behavior across applies. Bump deliberately when a new chart fixes a CVE or ships a desired feature."
  type        = string
  default     = "9.5.11"
}

variable "hostname" {
  description = "Public hostname Argo CD answers on. Embedded as `server.config.url` so generated redirect URIs and webhook callbacks resolve back to the public face."
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer URL. When set together with `oidc_client_id` and `oidc_client_secret`, the chart wires Dex with an OIDC connector and the UI gets a `Sign in with OIDC` button. Empty inputs disable the integration; only the chart-generated local admin remains."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "Client ID for the OIDC application Argo CD uses. Caller is responsible for creating the application in Zitadel and propagating the value here."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "Client secret for the OIDC application Argo CD uses. Sensitive — the value lands in a Helm-managed Secret inside the cluster."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_admin_groups" {
  description = "Group / role claims granted Argo CD's `role:admin` policy. Anyone whose ID token carries one of these claims gets full read/write across every Application/AppProject. Empty list = OIDC users have no permissions until the operator hand-edits the in-cluster ConfigMap."
  type        = list(string)
  default     = []
}

variable "node_selector" {
  description = "Node-selector applied to every Argo CD pod the chart creates (server, repo-server, application-controller, redis, dex). Empty = scheduler picks. Set on multi-node clusters where a specific tier should host the GitOps controller."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints every Argo CD pod tolerates. Empty list = pods cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "notifications_config" {
  description = "Decoded `notifications:` block (notifiers / templates / triggers) for the argo-cd chart's notifications subsystem, fed by the caller from `config/argocd-notifications.yaml`. The module forces `argocdUrl` from `hostname` and attaches the secret items itself, so those keys can be omitted here. An empty map leaves notifications untouched — the rendered values stay byte-identical and the chart behaves as before."
  type        = any
  default     = {}
}

variable "telegram_token" {
  description = "Telegram bot token written into `argocd-notifications-secret` (data key `telegram-token`, referenced as `$telegram-token` by the `service.telegram` notifier). Sensitive — it lands in a Helm-managed Secret and in Terraform state. Empty leaves the secret items empty so the notifier stays inert until a token is supplied."
  type        = string
  default     = ""
  sensitive   = true
}
