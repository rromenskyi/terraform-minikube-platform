variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  type    = bool
  default = true
}

variable "namespace" {
  type = string
}

variable "hostname" {
  description = "Public hostname Roundcube is reachable at (the same one Stalwart uses; Roundcube serves root, Stalwart admin lives at /admin and /account)."
  type        = string
}

variable "volume_base_path" {
  description = "Root directory on the host node for Roundcube's preferences SQLite DB."
  type        = string
}

variable "image" {
  description = "Roundcube container image. The Apache flavour is used because the upstream image bakes a working PHP+Apache config; the alpine-fpm flavour needs an extra fpm/nginx pair."
  type        = string
  default     = "roundcube/roundcubemail:1.6.16-apache"
}

variable "imap_host" {
  description = "In-cluster Stalwart IMAP service host. TLS on port 993 (`tls://...`)."
  type        = string
  default     = "stalwart.mail.svc.cluster.local"
}

variable "imap_port" {
  type    = number
  default = 993
}

variable "smtp_host" {
  description = "In-cluster Stalwart submission service host. TLS on port 465 (`ssl://...`)."
  type        = string
  default     = "stalwart.mail.svc.cluster.local"
}

variable "smtp_port" {
  type    = number
  default = 465
}

variable "zitadel_org_id" {
  type    = string
  default = ""
}

variable "zitadel_issuer_url" {
  type    = string
  default = ""
}

variable "zitadel_provider_authenticated" {
  type    = bool
  default = false
}

variable "zitadel_project_id" {
  description = "Existing Zitadel project this Roundcube OIDC app lands under. Reusing the Stalwart-tenant project keeps role grants in one place."
  type        = string
  default     = ""
}

variable "memory_request" {
  type    = string
  default = "128Mi"
}

variable "memory_limit" {
  type    = string
  default = "512Mi"
}

variable "cpu_request" {
  type    = string
  default = "20m"
}

variable "cpu_limit" {
  type    = string
  default = "500m"
}
