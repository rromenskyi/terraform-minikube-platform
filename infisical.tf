# Infisical — platform secrets store.
#
# Phase 0: brings up Infisical empty, recovery admin login.
# Phase 1 (this): Zitadel OIDC SSO via API. Operator-bootstrapped
# Universal-Auth machine identity (one-time UI step) authenticates
# the OIDC-config Job, same chicken-and-egg pattern as
# `TF_VAR_zitadel_pat`.
# Phase 2 (deferred): infisical-agent sidecar materialises k8s Secrets
# from Infisical paths. See `BACKLOG.md` for the full roadmap.

# ── Hard-fail checks for Phase 0 prerequisites ───────────────────────────────

check "infisical_requires_postgres" {
  assert {
    condition     = !local.platform.services.infisical.enabled || local.platform.services.postgres.enabled
    error_message = "services.infisical.enabled = true requires services.postgres.enabled = true (Infisical's main store, no internal fallback). Flip postgres on in config/platform.yaml."
  }
}

check "infisical_requires_redis" {
  assert {
    condition     = !local.platform.services.infisical.enabled || local.platform.services.redis.enabled
    error_message = "services.infisical.enabled = true requires services.redis.enabled = true (Infisical uses Redis for Bull queues + rate limiting, no internal fallback). Flip redis on in config/platform.yaml."
  }
}

check "infisical_hostname_set" {
  assert {
    condition     = !local.platform.services.infisical.enabled || local.platform.services.infisical.hostname != ""
    error_message = "services.infisical.hostname must be set when infisical is enabled (e.g. `secrets.example.com`). Drives SITE_URL + the IngressRoute Host(...) match."
  }
}

check "infisical_recovery_admin_email_set" {
  assert {
    condition     = !local.platform.services.infisical.enabled || local.platform.services.infisical.recovery_admin_email != ""
    error_message = "services.infisical.recovery_admin_email must be set when infisical is enabled — used as the bootstrap admin login until Phase 1 wires Zitadel OIDC SSO."
  }
}

# ── Phase 1 — Zitadel OIDC SSO checks ────────────────────────────────────────
#
# Phase 1 needs three things from the operator:
#   1. `services.zitadel.enabled = true` (we're using Zitadel as the OIDC IdP).
#   2. `services.infisical.organization_id` set to the org id Infisical assigned
#      during the Phase 0 recovery-admin signup. Lookup once: log into
#      Infisical, the URL becomes `https://<host>/org/<this-id>/...`. Yaml.
#   3. `TF_VAR_infisical_ua_client_id` + `TF_VAR_infisical_ua_client_secret`
#      from the operator-bootstrapped `tf-platform` Universal-Auth identity.
#      Same UI step Phase 0 took for the recovery admin — Org settings →
#      Access Control → Identities → Create `tf-platform` (role Admin) →
#      Authentication → Universal Auth → Create client_secret.

check "infisical_oidc_requires_zitadel" {
  assert {
    condition     = !local.platform.services.infisical.enable_oidc || local.platform.services.zitadel.enabled
    error_message = "services.infisical.enable_oidc = true requires services.zitadel.enabled = true (we use Zitadel as the OIDC IdP). Flip zitadel on or leave Infisical on Phase 0 (recovery-admin only)."
  }
}

check "infisical_oidc_organization_id_set" {
  assert {
    condition     = !local.platform.services.infisical.enable_oidc || local.platform.services.infisical.organization_id != ""
    error_message = "services.infisical.organization_id must be set when enable_oidc is true. Find it once after the Phase 0 signup: log into Infisical, the URL contains `/org/<id>/...`. Paste in config/platform.yaml."
  }
}

check "infisical_ua_credentials_set" {
  assert {
    condition     = !local.platform.services.infisical.enable_oidc || (var.infisical_ua_client_id != "" && var.infisical_ua_client_secret != "")
    error_message = "TF_VAR_infisical_ua_client_id and TF_VAR_infisical_ua_client_secret must be set when enable_oidc = true. One-time bootstrap: in Infisical UI, Org settings → Access Control → Identities → Create `tf-platform` (Admin role) → Authentication → Universal Auth → New Client Secret. Paste both values into .env."
  }
}

# ── Zitadel OIDC application — provisioned by the existing zitadel-app module
#
# Same module the kind:app components use, called from the platform
# root because Infisical lives in the platform namespace, not a tenant
# project. Roles `infisical_admin` and `infisical_user` are placeholders
# — Infisical's RBAC is internal; Zitadel role grant just gates "who can
# log in to Infisical at all" via the email-domain allowlist + the
# project_role_check Phase 1B can enable later.
module "infisical_zitadel_app" {
  source     = "./modules/zitadel-app"
  depends_on = [module.zitadel]

  count = local.platform.services.infisical.enable_oidc && local.platform.services.zitadel.enabled ? 1 : 0

  org_name     = "ZITADEL"
  project_name = "infisical"
  app_name     = "infisical"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  redirect_uris = [
    "https://${local.platform.services.infisical.hostname}/api/v1/sso/oidc/callback",
  ]
  post_logout_uris = [
    "https://${local.platform.services.infisical.hostname}/login",
  ]

  app_type    = "OIDC_APP_TYPE_WEB"
  auth_method = "OIDC_AUTH_METHOD_TYPE_BASIC"

  roles = [
    { key = "infisical_admin", display_name = "Infisical Admin" },
    { key = "infisical_user", display_name = "Infisical User" },
  ]

  secret_namespace = kubernetes_namespace_v1.platform.metadata[0].name
  secret_name      = "infisical-zitadel-oidc"
}

# ── Module call ──────────────────────────────────────────────────────────────

module "infisical" {
  source     = "./modules/infisical"
  depends_on = [module.addons, kubernetes_namespace_v1.platform, module.postgres, module.redis]

  enabled              = local.platform.services.infisical.enabled
  namespace            = kubernetes_namespace_v1.platform.metadata[0].name
  hostname             = local.platform.services.infisical.hostname
  recovery_admin_email = local.platform.services.infisical.recovery_admin_email

  postgres_host             = module.postgres.host
  postgres_namespace        = module.postgres.namespace
  postgres_superuser_secret = module.postgres.superuser_secret_name

  redis_host           = module.redis.host
  redis_namespace      = module.redis.namespace
  redis_default_secret = module.redis.default_secret_name

  # ── Phase 1 — OIDC ────────────────────────────────────────────────────────
  enable_oidc                = local.platform.services.infisical.enable_oidc
  oidc_issuer_url            = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  oidc_client_id             = local.platform.services.infisical.enable_oidc ? module.infisical_zitadel_app[0].client_id : ""
  oidc_client_secret         = local.platform.services.infisical.enable_oidc ? module.infisical_zitadel_app[0].client_secret : ""
  oidc_organization_id       = local.platform.services.infisical.organization_id
  oidc_allowed_email_domains = local.platform.services.infisical.allowed_email_domains
  infisical_ua_client_id     = var.infisical_ua_client_id
  infisical_ua_client_secret = var.infisical_ua_client_secret
}
