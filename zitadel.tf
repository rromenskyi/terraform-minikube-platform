# Shared Zitadel IdP — single source of OIDC/SAML auth for every
# project and the platform-admin surface.
#
# Lives in the root-owned `platform` namespace alongside MySQL /
# Postgres / Redis / Ollama. Backing store is the shared Postgres
# (db `platform_zitadel`, role `platform_zitadel`, provisioned by
# the module's bootstrap Job). Public ingress is registered the same
# way as Grafana / Traefik dashboard: a `kind: external` component
# in `config/components/zitadel.yaml` routed by a domain entry.
# Zitadel TF provider — used by `kind: app` components to
# auto-provision Project + OIDC Application + Roles + a k8s Secret
# with AUTH_ZITADEL_* envs ready for Auth.js / similar OIDC clients.
#
# Bootstrap is fully automated — no operator click anywhere:
#   1. modules/zitadel sets ZITADEL_FIRSTINSTANCE_ORG_MACHINE_* +
#      ZITADEL_FIRSTINSTANCE_PATPATH on the Zitadel pod, so on the
#      very first boot Zitadel creates a `tf-platform` machine user
#      and writes its Personal Access Token to a file inside an
#      emptyDir volume.
#   2. A `pat-broker` sidecar in the same Pod watches the file, then
#      kubectl-applies a `zitadel-tf-pat` Secret with the token.
#   3. modules/zitadel exposes the Secret value via the `tf_pat`
#      output (empty string during the first-apply window when the
#      sidecar hasn't run yet, real PAT on every apply after that).
#   4. This provider's `access_token` coalesces module output → the
#      legacy `var.zitadel_pat` (escape hatch for emergencies) → a
#      placeholder so provider config stays valid even on a clean
#      clone before Zitadel has ever booted.
#
# On a fresh cluster the very first apply will:
#   - create Zitadel + sidecar (provider gets PLACEHOLDER token, but
#     no kind:app components exist yet so no provider call is made)
#   - sidecar bootstraps the PAT Secret asynchronously
# Re-apply after that picks up the real PAT and provisions any
# kind:app components that show up in YAML.
# Read-only lookup of the FIRSTINSTANCE-bootstrapped PAT for the
# `zitadel_pat` output below. `kubernetes_resources` returns an empty
# `objects` list when the Secret doesn't exist yet (clean clone, pre-
# bootstrap), so the output degrades to "" instead of failing the
# whole plan. Refreshes on every plan/apply, so a freshly-populated
# Secret shows up on the next run.
# `count` gates the lookup on `services.zitadel.enabled` — when
# Zitadel is fully disabled the data source isn't fetched at all and
# the output collapses to "".
data "kubernetes_resources" "zitadel_tf_pat_output" {
  for_each = local.platform.services.zitadel.enabled ? toset(["enabled"]) : toset([])

  api_version = "v1"
  kind        = "Secret"
  namespace   = kubernetes_namespace_v1.platform.metadata[0].name
}

# Provider transport is operator-configurable via
# `services.zitadel.provider` in `config/platform.yaml`. Two modes
# the platform supports out of the box:
#
#   - "public" — provider connects to the real ExternalDomain over
#     HTTPS:443. Right answer when the ingress chain forwards HTTP/2
#     trailers cleanly (any direct ingress, most non-CF clouds, even
#     CF with the right Workers / Spectrum config).
#
#   - "port_forward" — provider connects to localhost:8080 over plain
#     HTTP, with the `./tf` wrapper running `kubectl port-forward
#     svc/zitadel 8080:8080` for the duration of the apply. Used here
#     because our deploy sits behind Cloudflare's pure-proxy mode,
#     which strips gRPC HTTP/2 trailers — the provider's grpc-go
#     client treats absent trailers as a stream-closed error. Verified
#     in the wild: same gRPC call via port-forward returns
#     `grpc-status: 2` trailer; through CF the response has no
#     trailers at all.
#
# `transport_headers.Host` is set to the ExternalDomain in both modes
# so Zitadel's multi-tenant instance lookup matches even when the
# transport host is `localhost`.
locals {
  # Empty `provider.host` falls back to the external_domain — saves
  # operators duplicating "id.example.com" in two places when running
  # in `public` mode.
  zitadel_provider_host = (
    local.platform.services.zitadel.provider.host == ""
    ? local.platform.services.zitadel.external_domain
    : local.platform.services.zitadel.provider.host
  )
}

provider "zitadel" {
  domain   = local.zitadel_provider_host
  insecure = tostring(local.platform.services.zitadel.provider.insecure)
  port     = tostring(local.platform.services.zitadel.provider.port)
  # PAT lives in the operator's `.env` as `TF_VAR_zitadel_pat` (one-
  # time setup — see operating.md → "Zitadel PAT bootstrap"). Empty
  # placeholder satisfies provider validation on a clean clone where
  # Zitadel hasn't been bootstrapped yet; the precondition below
  # catches the real misuse case (kind:app components active without
  # a PAT in `.env`).
  access_token = var.zitadel_pat != "" ? var.zitadel_pat : "PLACEHOLDER_BOOTSTRAP"

  transport_headers = {
    Host = local.platform.services.zitadel.external_domain
  }
}


module "zitadel" {
  source     = "./modules/zitadel"
  depends_on = [module.addons, module.postgres]

  enabled                   = local.platform.services.zitadel.enabled
  namespace                 = kubernetes_namespace_v1.platform.metadata[0].name
  postgres_host             = module.postgres.host
  postgres_superuser_secret = module.postgres.superuser_secret_name
  external_domain           = local.platform.services.zitadel.external_domain
  first_admin_email         = local.platform.services.zitadel.first_admin_email
  first_admin_username      = local.platform.services.zitadel.first_admin_username
  login_policy              = local.platform.services.zitadel.login_policy
  login_client_pat          = var.zitadel_login_client_pat

  node_selector = local.platform.services.zitadel.node_selector
  tolerations   = local.platform.services.zitadel.tolerations
}

# Default Login Policy reconciler.
#
# Zitadel's v4 FirstInstance steps schema dropped LoginPolicy — without
# this resource the instance boots with Zitadel's built-in defaults
# (registration ON, etc.) regardless of `services.zitadel.login_policy`
# in `config/platform.yaml`. The native zitadel provider talks to the
# kubectl-port-forward bypass started by `./tf` (see `provider "zitadel"`
# config above), so what used to be a bash + curl null_resource inside
# `modules/zitadel` becomes a direct provider call here.
#
# Hosted at root rather than inside `modules/zitadel` because consumer
# modules used to declare `depends_on = [module.zitadel]` plus their own
# `data "zitadel_orgs" "this"` lookup. Terraform defers data sources
# inside a depends_on'd module to apply-time whenever the depended-on
# module has any pending changes, which would propagate as
# `(known after apply)` on `org_id` and force "must be replaced" on
# every downstream `zitadel_project` / `zitadel_application_oidc` /
# `zitadel_project_role` (and rotate forward-auth + dash login + the
# Stalwart OIDC chain on every apply that touched the policy). The
# accompanying refactor in this same change moves `data "zitadel_orgs"`
# to root and threads `org_id` into oauth2-proxy / zitadel-app via
# input variables, dropping the module-level depends_on entirely. The
# data-source-defer condition can no longer fire, so this resource
# lives at the level that owns the lookup.
resource "zitadel_default_login_policy" "main" {
  count      = local.platform.services.zitadel.enabled ? 1 : 0
  depends_on = [module.zitadel]

  allow_register     = local.platform.services.zitadel.login_policy.allow_register
  allow_external_idp = local.platform.services.zitadel.login_policy.allow_external_idp
  # `user_login` is the v2 gRPC equivalent of the v1 REST
  # `allowUsernamePassword` field — both gate the username+password
  # form on the login page.
  user_login               = local.platform.services.zitadel.login_policy.allow_username_password
  passwordless_type        = "PASSWORDLESS_TYPE_ALLOWED"
  ignore_unknown_usernames = true

  password_check_lifetime       = "864000s"
  external_login_check_lifetime = "864000s"
  mfa_init_skip_lifetime        = "2592000s"
  second_factor_check_lifetime  = "64800s"
  multi_factor_check_lifetime   = "43200s"

  force_mfa                = false
  force_mfa_local_only     = false
  hide_password_reset      = false
  allow_domain_discovery   = false
  disable_login_with_email = false
  disable_login_with_phone = false

  default_redirect_uri = ""

  # MFA factors. Zitadel ships these enabled out of the box and the
  # operator hasn't disabled them; an empty `multi_factors` / `second_factors`
  # in the resource definition would clear them on apply, silently
  # dropping U2F + TOTP from the login form. Pin to the defaults.
  multi_factors  = ["MULTI_FACTOR_TYPE_U2F_WITH_VERIFICATION"]
  second_factors = ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]
}
