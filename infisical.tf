# Infisical — platform secrets store.
#
# Phase 0 wiring: when `services.infisical.enabled: true` in
# `config/platform.yaml`, the module brings up Infisical alongside
# Zitadel/Stalwart in the platform namespace. No consumer rewiring
# yet — every secret in the cluster still lives where it always lived
# (`kubernetes_secret_v1`, `random_password` outputs, the cheatsheet).
# Phase 1 (next PR) wires Zitadel OIDC SSO. Phase 2 introduces the
# infisical-agent sidecar that materialises k8s Secrets from Infisical
# paths. See `BACKLOG.md` for the full roadmap.

# Infisical needs Postgres for its main store and Redis for queues +
# rate limiting. Neither has an internal-fallback option, unlike
# Stalwart's RocksDB. Fail plan up front rather than letting the
# Deployment crash-loop on a missing dep.
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
}
