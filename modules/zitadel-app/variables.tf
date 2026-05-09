variable "org_id" {
  description = "Zitadel org id the project + app live under. Caller resolves at root via `data \"zitadel_orgs\" \"platform_org\"` and passes the value down. Owning the data source at root rather than inside this module avoids the apply-time defer that propagates as `must be replaced` on every downstream resource whenever any consumer module declares `depends_on = [module.zitadel]`."
  type        = string
}

variable "project_name" {
  description = "Zitadel Project name. v1 limitation: one project per app (every `kind: app` component gets its own project, named after the app). Sharing a project across apps is a follow-up — would need project creation hoisted out of this per-app module."
  type        = string
}

variable "app_name" {
  description = "Zitadel Application name. Component name is the natural pick."
  type        = string
}

variable "issuer_url" {
  description = "Zitadel public issuer URL (e.g. https://id.example.com). Embedded into the AUTH_ZITADEL_ISSUER env var so client apps don't have to repeat it."
  type        = string
}

variable "redirect_uris" {
  description = "Full URLs Zitadel will allow as auth-code callback destinations. Built upstream from component hostnames + `oidc.redirect_paths` (e.g. `[\"https://app.example.com/auth/callback/zitadel\"]`)."
  type        = list(string)
  default     = []
}

variable "post_logout_uris" {
  description = "URLs Zitadel will allow as post-logout redirect destinations. Built upstream from component hostnames + `oidc.post_logout_paths`."
  type        = list(string)
  default     = []
}

variable "grant_types" {
  description = "OIDC grant types. Default = Authorization Code + Refresh Token, the standard combo for SSR web apps."
  type        = list(string)
  default     = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
}

variable "response_types" {
  description = "OIDC response types. Default = Authorization Code flow only."
  type        = list(string)
  default     = ["OIDC_RESPONSE_TYPE_CODE"]
}

variable "app_type" {
  description = "Zitadel app type — WEB (server-side, has client_secret), USER_AGENT (SPA, PKCE), NATIVE (mobile, PKCE)."
  type        = string
  default     = "OIDC_APP_TYPE_WEB"
}

variable "auth_method" {
  description = "Client auth method when redeeming auth codes. BASIC = client_id:client_secret in Authorization header. NONE = PKCE only (use for SPA/native)."
  type        = string
  default     = "OIDC_AUTH_METHOD_TYPE_BASIC"
}

variable "dev_mode" {
  description = "Allow `http://` and `localhost` redirect URIs. Off by default (production-style strict). Flip on while iterating locally."
  type        = bool
  default     = false
}

variable "roles" {
  description = "Project roles to create — each becomes a Zitadel role grantable to users (platform_admin, tenant_admin, user, etc). The role keys land in the user's OIDC token under `urn:zitadel:iam:org:project:roles` and downstream apps gate features on them."
  type = list(object({
    key          = string
    display_name = string
    group        = optional(string, "")
  }))
  default = []
}

variable "secret_namespace" {
  description = "K8s namespace where the Secret holding AUTH_ZITADEL_* + AUTH_SECRET lands."
  type        = string
}

variable "secret_name" {
  description = "Name of the Secret to create."
  type        = string
}

variable "secret_formats" {
  description = "List of env-name conventions to materialise inside the emitted Secret. Each format adds a parallel set of keys with the same client_id / client_secret / issuer values rendered under the env names that format expects. Multiple formats stack non-destructively — a chart that reads any one of them works without engine changes. Supported values: `auth_js` (default — emits AUTH_ZITADEL_ISSUER / AUTH_ZITADEL_ID / AUTH_ZITADEL_SECRET / AUTH_SECRET, the @auth/sveltekit + Auth.js convention), `open_webui` (OAUTH_CLIENT_ID / OAUTH_CLIENT_SECRET / OPENID_PROVIDER_URL — Open WebUI's `ENABLE_OAUTH_SIGNUP` path), `grafana_oauth` (GF_AUTH_GENERIC_OAUTH_CLIENT_ID / GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET / GF_AUTH_GENERIC_OAUTH_AUTH_URL / _TOKEN_URL / _API_URL — Grafana's generic OAuth provider). Empty list disables every format (Secret still created but data-only — engine consumers can read raw `*` outputs)."
  type        = list(string)
  default     = ["auth_js"]
  validation {
    condition = alltrue([
      for f in var.secret_formats : contains(["auth_js", "open_webui", "grafana_oauth"], f)
    ])
    error_message = "Each `secret_formats` entry must be one of: auth_js, open_webui, grafana_oauth."
  }
}
