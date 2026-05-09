variable "enabled" {
  description = "Deploy the auth gate. Should be tied to `services.zitadel.enabled` at the root — this module needs Zitadel as the OIDC provider."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the Deployment lives in. Expected to exist already (typically `ingress-controller`)."
  type        = string
  default     = null
}

variable "image" {
  description = "Container image. Pinned tag so the OIDC config schema doesn't shift between restarts."
  type        = string
  default     = "thomseddon/traefik-forward-auth:2.2.0"
}

variable "issuer_url" {
  description = "Zitadel public issuer URL (e.g. https://id.example.com)."
  type        = string
}

variable "auth_hostname" {
  description = "Public hostname this proxy answers on (e.g. auth.example.com). Used as the OIDC redirect URI host and as the auth-host (`/_oauth` callback lands here for every protected subdomain)."
  type        = string
}

variable "cookie_domain" {
  description = "Cookie scope. Set to the parent domain WITHOUT a leading dot (e.g. `example.com`) — traefik-forward-auth canonicalises this and emits cookies that cover every subdomain."
  type        = string
}

variable "zitadel_org_id" {
  description = "Zitadel org id the project + app live under. Caller resolves this at root via `data \"zitadel_orgs\" \"platform_org\"` and passes the value down — keeping the data source out of this module avoids the apply-time defer that consumer modules with `depends_on = [module.zitadel]` would otherwise hit and which cascades into `must be replaced` on every downstream resource."
  type        = string
}

variable "zitadel_provider_authenticated" {
  description = "True when the root TF has been handed a non-empty `TF_VAR_zitadel_pat` for the Zitadel provider. False trips the precondition so the operator gets a clear error instead of an opaque provider 'unauthenticated' on apply."
  type        = bool
  default     = false
}

variable "memory_request" {
  type    = string
  default = "16Mi"
}

variable "memory_limit" {
  type    = string
  default = "64Mi"
}

variable "cpu_request" {
  type    = string
  default = "10m"
}

variable "cpu_limit" {
  type    = string
  default = "100m"
}
