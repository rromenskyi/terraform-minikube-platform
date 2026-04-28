# Shared Zitadel IdP — single source of OIDC/SAML auth for every
# project and the platform-admin surface.
#
# Lives in the root-owned `platform` namespace alongside MySQL /
# Postgres / Redis / Ollama. Backing store is the shared Postgres
# (db `platform_zitadel`, role `platform_zitadel`, provisioned by
# the module's bootstrap Job). Public ingress is registered the same
# way as Grafana / Traefik dashboard: a `kind: external` component
# in `config/components/zitadel.yaml` routed by a domain entry.
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
}
