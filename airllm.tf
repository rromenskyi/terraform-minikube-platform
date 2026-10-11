# AirLLM — self-hosted LLM gateway (github.com/ipsupport-llc/ipsupport-airllm),
# deployed from its PUBLIC Helm chart via Argo CD (modules/airllm).
#
# Two instances, each configured in the gitignored `config/platform.yaml`:
#   - `services.airllm`     — the main instance, typically pinned to a release
#     tag;
#   - `services.airllm_dev` — a development instance next to it, typically
#     tracking main. It can start from a one-time copy of the main instance's
#     database (sharing its master key, so the copied provider credentials
#     decrypt) and log in through Zitadel.

locals {
  airllm     = local.platform.services.airllm # defaults + gitignored overrides, normalized in locals.tf
  airllm_dev = local.platform.services.airllm_dev

  airllm_enabled  = local.airllm.enabled
  airllm_repo_url = local.airllm.repo_url

  # Applications Argo CD's `platform` AppProject admits (argocd.tf).
  airllm_argocd_apps = concat(
    local.airllm.enabled ? [{ repo_url = local.airllm_repo_url, namespace = local.airllm.namespace }] : [],
    local.airllm_dev.enabled ? [{ repo_url = local.airllm_repo_url, namespace = local.airllm_dev.namespace }] : [],
  )

  airllm_dev_oidc_enabled = local.airllm_dev.enabled && local.airllm_dev.oidc && local.platform.services.zitadel.enabled
}

module "airllm" {
  source = "./modules/airllm"

  enabled   = local.airllm.enabled
  name      = "airllm"
  namespace = local.airllm.namespace
  tags      = module.platform_label.tags
  app_env   = "prod"

  repo_url       = local.airllm_repo_url
  chart_revision = local.airllm.chart_revision
  image_tag      = local.airllm.image_tag
  replicas       = local.airllm.replicas
  node_selector  = local.airllm.node_selector

  argocd_namespace          = local.platform.services.argocd.namespace
  setup_namespace           = kubernetes_namespace_v1.platform.metadata[0].name
  postgres_host             = module.postgres.host
  postgres_superuser_secret = module.postgres.superuser_secret_name
  database_name             = "airllm"
  redis_host                = module.redis.host
  redis_port                = module.redis.port
  redis_db                  = 0
  redis_acl_namespace       = module.redis.acl_namespace

  google_service_account = local.airllm.google_service_account
  gcp_wif_audience       = local.platform.services.gcp_wif.pool_provider_audience

  hostname           = local.airllm.hostname
  cloudflare_zone_id = local.airllm.cloudflare_zone_id
  public_ip          = local.airllm.public_ip
}

module "airllm_dev" {
  source = "./modules/airllm"

  enabled   = local.airllm_dev.enabled
  name      = "airllm-dev"
  namespace = local.airllm_dev.namespace
  tags      = module.platform_label.tags
  app_env   = "dev"

  repo_url       = local.airllm_repo_url
  chart_revision = local.airllm_dev.chart_revision
  image_tag      = local.airllm_dev.image_tag
  replicas       = local.airllm_dev.replicas
  node_selector  = local.airllm_dev.node_selector
  # The chart's dashboards have fixed uids (the main instance ships them)
  # and dev alerts should not page anyone.
  dashboards_enabled      = false
  prometheus_rule_enabled = false

  argocd_namespace          = local.platform.services.argocd.namespace
  setup_namespace           = kubernetes_namespace_v1.platform.metadata[0].name
  postgres_host             = module.postgres.host
  postgres_superuser_secret = module.postgres.superuser_secret_name
  database_name             = "airllm_dev"
  seed_from_database        = local.airllm_dev.seed_from_airllm ? "airllm" : ""
  master_key                = local.airllm_dev.seed_from_airllm ? module.airllm.master_key : ""
  redis_host                = module.redis.host
  redis_port                = module.redis.port
  redis_db                  = local.airllm_dev.redis_db
  redis_acl_namespace       = module.redis.acl_namespace

  # Roles come from the `groups` claim (zitadel_actions.tf), which holds only
  # the role keys the user is granted in this instance's own Zitadel project
  # (`module.airllm_dev_oidc`). Grant `airllm_dev_admin` / `airllm_dev_user`
  # there; roles from other projects (`platform_admin`) never reach it.
  oidc = local.airllm_dev_oidc_enabled ? {
    issuer      = "https://${local.platform.services.zitadel.external_domain}"
    client_id   = module.airllm_dev_oidc["enabled"].client_id
    roles_claim = "groups"
    role_map    = "airllm_dev_admin:airllm_admin,airllm_dev_user:airllm_user"
  } : null
  oidc_client_secret = local.airllm_dev_oidc_enabled ? module.airllm_dev_oidc["enabled"].client_secret : ""

  google_service_account = local.airllm_dev.google_service_account
  gcp_wif_audience       = local.platform.services.gcp_wif.pool_provider_audience

  hostname           = local.airllm_dev.hostname
  cloudflare_zone_id = local.airllm_dev.cloudflare_zone_id
  public_ip          = local.airllm_dev.public_ip
}

# Zitadel project + OIDC application for the dev instance. The app reads the
# client id from its values and the client secret from its runtime Secret;
# the Secret this module emits (data only, no env formats) is not consumed.
module "airllm_dev_oidc" {
  source   = "./modules/zitadel-app"
  for_each = local.airllm_dev_oidc_enabled ? toset(["enabled"]) : toset([])

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = data.zitadel_orgs.platform_org["enabled"].ids[0]
  project_name = "airllm-dev"
  app_name     = "airllm-dev"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  redirect_uris    = ["https://${local.airllm_dev.hostname}/auth/callback"]
  post_logout_uris = ["https://${local.airllm_dev.hostname}/"]

  secret_name      = "airllm-dev-oidc"
  secret_namespace = module.airllm_dev.namespace
  secret_formats   = []

  roles = [
    { key = "airllm_dev_admin", display_name = "AirLLM dev admin" },
    { key = "airllm_dev_user", display_name = "AirLLM dev user" },
  ]
}

# ── State moves: the main instance's resources moved into modules/airllm ────

moved {
  from = kubernetes_namespace_v1.airllm
  to   = module.airllm.kubernetes_namespace_v1.this
}

moved {
  from = random_password.airllm_db
  to   = module.airllm.random_password.db
}

moved {
  from = kubernetes_secret_v1.airllm_postgres_setup_env
  to   = module.airllm.kubernetes_secret_v1.postgres_setup_env
}

moved {
  from = kubernetes_job_v1.airllm_postgres_setup
  to   = module.airllm.kubernetes_job_v1.postgres_setup
}

moved {
  from = random_bytes.airllm_master_key
  to   = module.airllm.random_bytes.master_key
}

moved {
  from = random_bytes.airllm_session_key
  to   = module.airllm.random_bytes.session_key
}

moved {
  from = random_password.airllm_admin
  to   = module.airllm.random_password.admin
}

moved {
  from = random_password.airllm_redis
  to   = module.airllm.random_password.redis
}

moved {
  from = kubernetes_secret_v1.airllm_redis_acl_scoped
  to   = module.airllm.kubernetes_secret_v1.redis_acl
}

moved {
  from = kubernetes_secret_v1.airllm
  to   = module.airllm.kubernetes_secret_v1.runtime
}

moved {
  from = kubectl_manifest.airllm_application
  to   = module.airllm.kubectl_manifest.application
}

moved {
  from = cloudflare_dns_record.airllm
  to   = module.airllm.cloudflare_dns_record.this
}

moved {
  from = kubectl_manifest.airllm_certificate
  to   = module.airllm.kubectl_manifest.certificate
}

moved {
  from = kubectl_manifest.airllm_redirect_middleware
  to   = module.airllm.kubectl_manifest.redirect_middleware
}

moved {
  from = kubectl_manifest.airllm_ingressroute_web
  to   = module.airllm.kubectl_manifest.ingressroute_web
}

moved {
  from = kubectl_manifest.airllm_ingressroute
  to   = module.airllm.kubectl_manifest.ingressroute
}
