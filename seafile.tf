# Seafile community edition — root wiring.
#
# Module emits the Deployment + Service + IngressRoute + PVC + MySQL
# setup Job + bootstrap Secret + Seahub settings ConfigMap. Zitadel
# OIDC client lives in a sibling `module "seafile_oidc"` callsite,
# wired into the main module via client_id / client_secret outputs
# (same pattern as `module.argocd_oidc` → `module.argocd`).

check "seafile_requires_mysql" {
  assert {
    condition     = !local.platform.services.seafile.enabled || local.platform.services.mysql.enabled
    error_message = "services.seafile.enabled = true requires services.mysql.enabled = true (Seafile 13 CE is MySQL-only — Postgres unsupported upstream)."
  }
}

check "seafile_requires_redis" {
  assert {
    condition     = !local.platform.services.seafile.enabled || local.platform.services.redis.enabled
    error_message = "services.seafile.enabled = true requires services.redis.enabled = true (Seafile 13 default cache backend)."
  }
}

check "seafile_external_hostname_set" {
  assert {
    condition     = !local.platform.services.seafile.enabled || local.platform.services.seafile.external_hostname != ""
    error_message = "services.seafile.enabled = true requires services.seafile.external_hostname to be set (e.g. `cloud.example.com`). Empty would emit an IngressRoute with no Host matcher and Seahub generates broken self-referential URLs."
  }
}

check "seafile_admin_email_set" {
  assert {
    condition     = !local.platform.services.seafile.enabled || local.platform.services.seafile.admin_email != ""
    error_message = "services.seafile.enabled = true requires services.seafile.admin_email to be set. Used as the bootstrap super-user email (Seafile 13 init script writes this into the DB on first boot)."
  }
}

module "seafile_oidc" {
  source     = "./modules/zitadel-app"
  for_each   = local.platform.services.seafile.enabled && local.platform.services.zitadel.enabled ? toset(["enabled"]) : toset([])
  depends_on = [module.zitadel]

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org["enabled"].ids[0] : ""
  project_name = "seafile"
  app_name     = "seafile"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  # Seahub's OAuth callback is fixed at `/oauth/callback/`.
  redirect_uris    = ["https://${local.platform.services.seafile.external_hostname}/oauth/callback/"]
  post_logout_uris = ["https://${local.platform.services.seafile.external_hostname}/"]

  # OIDC Secret targeted at `platform` ns (always exists at apply
  # time) rather than the Seafile ns — avoids a chicken-and-egg
  # between this module (creates the Secret) and module.seafile
  # (creates the ns + consumes client_id/secret via TF outputs into
  # the seahub_settings.py ConfigMap, not via Secret envFrom). The
  # Secret itself is currently unused; left in place for future
  # operators who may swap to env-from-Secret chart-side consumption.
  secret_name      = "seafile-oidc"
  secret_namespace = "platform"

  # Single role for now — anyone with seafile_user can sign in.
  # Seafile-side admin is still the bootstrap super-user; no
  # claim-driven role mapping in Seafile CE 13.
  roles = [
    { key = "seafile_user", display_name = "Seafile User" },
  ]
}

module "seafile" {
  source     = "./modules/seafile"
  depends_on = [module.mysql, module.redis, module.seafile_oidc]

  context = module.platform_label.context
  enabled = local.platform.services.seafile.enabled

  namespace         = local.platform.services.seafile.namespace
  image_tag         = local.platform.services.seafile.image_tag
  external_hostname = local.platform.services.seafile.external_hostname
  admin_email       = local.platform.services.seafile.admin_email

  mysql_host          = "mysql.platform.svc.cluster.local"
  mysql_port          = 3306
  mysql_root_password = local.platform.services.mysql.enabled ? module.mysql.root_password : ""

  redis_host     = "redis.platform.svc.cluster.local"
  redis_port     = 6379
  redis_password = local.platform.services.redis.enabled ? module.redis.default_password : ""

  storage_class = local.platform.services.seafile.storage_class
  storage_size  = local.platform.services.seafile.storage_size

  oidc_issuer_url    = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  oidc_client_id     = try(module.seafile_oidc["enabled"].client_id, "")
  oidc_client_secret = try(module.seafile_oidc["enabled"].client_secret, "")

  timezone       = local.platform.services.seafile.timezone
  cpu_request    = local.platform.services.seafile.cpu_request
  cpu_limit      = local.platform.services.seafile.cpu_limit
  memory_request = local.platform.services.seafile.memory_request
  memory_limit   = local.platform.services.seafile.memory_limit
  node_selector  = local.platform.services.seafile.node_selector
  tolerations    = local.platform.services.seafile.tolerations
}

output "seafile_url" {
  description = "Public Seafile URL. Null when disabled."
  value       = local.platform.services.seafile.enabled ? module.seafile.external_url : null
}

output "seafile_admin_email" {
  description = "Bootstrap super-user email."
  value       = local.platform.services.seafile.enabled ? module.seafile.admin_email : null
}

output "seafile_admin_password" {
  description = "Sensitive — bootstrap super-user password. Surface with `terraform output -raw seafile_admin_password`. Ignored after first boot — Seahub UI rotates the actual stored value."
  value       = local.platform.services.seafile.enabled ? module.seafile.admin_password : null
  sensitive   = true
}
