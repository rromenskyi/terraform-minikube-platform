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
# PAT lookup at root scope — NOT inside modules/zitadel — so the data
# source has no depends_on chain to the Deployment and resolves at
# refresh time independent of the module's apply state. Empty `objects`
# list on first apply (Secret doesn't exist yet); populated thereafter.
# Going through the root keeps `provider "zitadel"` from picking up an
# `(known after apply)` value, which Terraform refuses to validate at
# plan time.
data "kubernetes_resources" "zitadel_tf_pat" {
  api_version = "v1"
  kind        = "Secret"
  namespace   = kubernetes_namespace_v1.platform.metadata[0].name
  # field_selector "metadata.name=..." is silently ignored by the
  # Terraform kubernetes provider's resources data source — it does
  # not propagate the selector to the API list call. Filter in HCL
  # instead from the full namespace listing.
  label_selector = ""
}

locals {
  zitadel_tf_pat_secrets = [
    for o in data.kubernetes_resources.zitadel_tf_pat.objects :
    o if o.metadata.name == "zitadel-tf-pat"
  ]
  zitadel_tf_pat = try(
    base64decode(local.zitadel_tf_pat_secrets[0].data.access_token),
    ""
  )
}

provider "zitadel" {
  domain       = local.platform.services.zitadel.external_domain
  insecure     = "false"
  port         = "443"
  access_token = coalesce(local.zitadel_tf_pat, var.zitadel_pat, "PLACEHOLDER_BOOTSTRAP")
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
}
