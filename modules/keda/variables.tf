variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module chains its own label off the platform-wide context. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to deploy KEDA. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace KEDA lives in. Tenants that let KEDA poll their workloads (for example a `metrics-api` trigger) allow ingress from this namespace by name, so keep it stable."
  type        = string
  default     = "keda"
}

variable "version_pin" {
  description = "Helm chart version for kedacore/keda (chart and app versions match). Pinned so an upstream release doesn't change CRD shape or defaults across applies."
  type        = string
  default     = "2.21.0"
}

variable "node_selector" {
  description = "Node selector for every KEDA pod (operator, metrics API server, webhooks). Empty map = land wherever k8s schedules."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for every KEDA pod, in the k8s toleration shape (`key`, `operator`, `value`, `effect`)."
  type        = list(any)
  default     = []
}
