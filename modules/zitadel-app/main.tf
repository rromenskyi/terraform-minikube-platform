terraform {
  required_providers {
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── Inputs ────────────────────────────────────────────────────────────────────

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

# ── Resources ─────────────────────────────────────────────────────────────────

resource "zitadel_project" "this" {
  org_id = var.org_id
  name   = var.project_name

  # Standard production defaults. project_role_assertion = put roles
  # into the ID token (Auth.js reads from there). project_role_check
  # off because a role is an authorization signal, not an authn gate
  # — let the app decide what unroled users can see.
  project_role_assertion = true
  project_role_check     = false
  has_project_check      = false
}

resource "zitadel_project_role" "roles" {
  for_each = { for r in var.roles : r.key => r }

  org_id       = var.org_id
  project_id   = zitadel_project.this.id
  role_key     = each.value.key
  display_name = each.value.display_name
  group        = each.value.group
}

resource "zitadel_application_oidc" "this" {
  org_id     = var.org_id
  project_id = zitadel_project.this.id
  name       = var.app_name

  redirect_uris             = var.redirect_uris
  post_logout_redirect_uris = var.post_logout_uris
  response_types            = var.response_types
  grant_types               = var.grant_types
  app_type                  = var.app_type
  auth_method_type          = var.auth_method
  dev_mode                  = var.dev_mode

  # ID-token enrichment so Auth.js / similar can decode roles from
  # the JWT without a follow-up /userinfo call.
  id_token_role_assertion      = true
  id_token_userinfo_assertion  = true
  access_token_role_assertion  = true
  access_token_type            = "OIDC_TOKEN_TYPE_BEARER"
  additional_origins           = []
  clock_skew                   = "0s"
  version                      = "OIDC_VERSION_1_0"
  skip_native_app_success_page = false
  back_channel_logout_uri      = ""
}

# Cookie / session encryption key for downstream Auth.js (or similar).
# Generated once per app, lives in TF state, mounted into the pod via
# the Secret below. Replace via `terraform taint` if you ever need to
# rotate (will invalidate every existing user session).
resource "random_password" "auth_secret" {
  length  = 64
  special = false
}

resource "kubernetes_secret_v1" "oidc" {
  metadata {
    name      = var.secret_name
    namespace = var.secret_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "oidc-credentials"
    }
  }

  data = {
    AUTH_ZITADEL_ISSUER = var.issuer_url
    AUTH_ZITADEL_ID     = zitadel_application_oidc.this.client_id
    AUTH_ZITADEL_SECRET = zitadel_application_oidc.this.client_secret
    AUTH_SECRET         = random_password.auth_secret.result
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "secret_name" {
  value       = kubernetes_secret_v1.oidc.metadata[0].name
  description = "Name of the Secret holding AUTH_ZITADEL_ISSUER, AUTH_ZITADEL_ID, AUTH_ZITADEL_SECRET, AUTH_SECRET — feed into the component as `oidc_secret_name`."
}

output "secret_checksum" {
  description = "SHA1 of the OIDC Secret's data, surfaced for use as a pod-template `checksum/oidc` annotation. Drives a Deployment rollout when the Zitadel app is recreated (e.g. after `terraform destroy`+`apply`, or after a manual app rotation in Zitadel) so the pod picks up the new client_id/client_secret instead of carrying the stale env from its previous start. The hash itself reveals nothing — `nonsensitive()` is used to drop the sensitivity bit so the annotation is renderable."
  value = nonsensitive(sha1(jsonencode({
    issuer        = var.issuer_url
    client_id     = zitadel_application_oidc.this.client_id
    client_secret = zitadel_application_oidc.this.client_secret
    auth_secret   = random_password.auth_secret.result
  })))
}

output "project_id" {
  value = zitadel_project.this.id
}

output "app_id" {
  value = zitadel_application_oidc.this.id
}

output "client_id" {
  value     = zitadel_application_oidc.this.client_id
  sensitive = true
}

output "client_secret" {
  value       = zitadel_application_oidc.this.client_secret
  sensitive   = true
  description = "Generated client secret for the OIDC application. Consumed directly when the downstream module renders Helm values that need the secret inline (e.g. Argo CD's Dex connector). Most kind:app components mount the AUTH_ZITADEL_SECRET key from the emitted k8s Secret instead — this output is for the rare case where Helm-time interpolation is needed."
}
