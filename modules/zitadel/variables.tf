variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy Zitadel. When false, no resources are created."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace Zitadel lives in. Expected to exist already (root-owned `platform`). Null when disabled."
  type        = string
  default     = null
}

variable "image" {
  description = "Zitadel main container image. v4 dropped the embedded Angular login form — the login UI now lives in the separate Next.js sidecar (`login_image`). Together with the FirstInstance machine-user PAT we bootstrap to disk, the chicken-and-egg of provisioning login-v2's service account vanishes."
  type        = string
  default     = "ghcr.io/zitadel/zitadel:v4.14.0"
}

variable "login_image" {
  description = "Zitadel Login UI v2 sidecar image. Pinned to the last tagged release — the rolling `:main` tag has been observed to ship a SPA race that double-submits `createCallback` and trips `Auth Request has already been handled (COMMAND-Sx208nt)` on every OIDC flow, breaking forward-auth-style gates. The wait-for-token-file behaviour we used to need from `:main` is now done in this module's own container `command` override, so the tagged release is fine."
  type        = string
  default     = "ghcr.io/zitadel/login:v3.0.1"
}

variable "postgres_host" {
  description = "In-cluster Postgres hostname (e.g. postgres.platform.svc.cluster.local)."
  type        = string
}

variable "postgres_superuser_secret" {
  description = "Name of the Secret (in this namespace) holding the Postgres superuser password. Used by the bootstrap Job to CREATE DATABASE / CREATE ROLE."
  type        = string
}

variable "external_domain" {
  description = "Public hostname Zitadel issues tokens for (e.g. id.example.com). Sets ExternalDomain — every OIDC issuer URL, redirect callback and email link references this host. Changing it later invalidates existing client redirect URIs."
  type        = string
}

variable "node_selector" {
  description = "Node-selector labels every Zitadel pod (main + login + Jobs) must match. Empty = scheduler picks. Set to pin onto the node carrying the platform's stateful tier."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints every Zitadel pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "first_admin_email" {
  description = "Email address of the bootstrap human admin (lands on the master instance). Pre-verified so login works without SMTP."
  type        = string
}

variable "first_admin_username" {
  description = "Username for the bootstrap human admin."
  type        = string
  default     = "zitadel-admin"
}

variable "login_client_pat" {
  description = "Pre-existing PAT for the `login-client` machine user. FIRSTINSTANCE writes a fresh PAT to an emptyDir on first install; that file is lost on pod restart and the Login UI v2 sidecar hangs forever waiting for it. Setting this var to an existing PAT (regenerated via the management API once and pasted into the operator's `.env`) makes the deployment mount it from a Secret instead, surviving any number of pod restarts. Empty (default) keeps the original FIRSTINSTANCE-only behavior — fine on a fresh install, broken on every subsequent restart."
  type        = string
  default     = ""
  sensitive   = true
}

variable "login_policy" {
  description = <<-EOT
    Default Login Policy applied at FIRSTINSTANCE bootstrap. Sets the
    instance-wide gate for self-service registration, external IDP
    federation, and username/password login. Secure default: registration
    OFF (operator decides who joins; nobody self-onboards), Google/SAML
    federation ON (so wired IDPs work), username/password ON (so the
    bootstrap admin can log in).

    NOTE: FIRSTINSTANCE config takes effect only on the very first boot
    against an empty database. Tweaking these values on an existing
    instance is what the root `zitadel_default_login_policy.main`
    resource (in `zitadel.tf`) is for — it reads this same struct via
    `local.platform.services.zitadel.login_policy` and reconciles
    against the live instance every apply.
  EOT
  type = object({
    allow_register          = optional(bool, false)
    allow_external_idp      = optional(bool, true)
    allow_username_password = optional(bool, true)
  })
  default = {}
}
