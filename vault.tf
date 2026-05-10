# Vault community — platform secrets store.
#
# Architecture (read modules/vault/main.tf header for the full version):
#   - Phase 0 (live): server StatefulSet, raft single-node, auto-unseal.
#   - Phase 1 (live, PRs #117/#118/#119): post-init bootstrap Job +
#     vault-config-operator + base CRDs (KV-v2 mount, VSO read-only
#     policy + role).
#   - Phase 2 (this file's wiring + module Phase 2 block): Zitadel app
#     for Vault + OIDC auth method via vco CRDs + per-tenant policies +
#     OIDC roles + hashicorp/vault-secrets-operator (VSO) install.
#     After this lands operator + tenants log into Vault UI via Zitadel
#     SSO, scoped to their policy; engine VaultStaticSecret CRs in
#     tenant namespaces are reconciled by VSO into k8s Secrets.

check "vault_hostname_set" {
  assert {
    condition     = !local.platform.services.vault.enabled || local.platform.services.vault.hostname != ""
    error_message = "services.vault.hostname must be set when vault is enabled (e.g. `vault.example.com`). Drives the IngressRoute Host(...) match. Add the matching `<prefix>: vault` route to your domain yaml so cloudflared sees the hostname through the same project-IngressRoute pipeline as Stalwart and oauth2-proxy."
  }
}

# Zitadel application for Vault — gives the OIDC auth method its
# client_id / client_secret. Module emits a k8s Secret carrying the
# OIDC env vars; we lift only client_id / client_secret out of the
# module's outputs (Vault doesn't run as a SvelteKit app, so the
# AUTH_ZITADEL_* envFrom convention isn't useful here — vco's
# JWTOIDCAuthEngineConfig CR consumes a Secret in its own namespace
# created by `module.vault`).
module "vault_oidc" {
  source     = "./modules/zitadel-app"
  for_each   = local.platform.services.vault.enabled && local.platform.services.zitadel.enabled ? toset(["enabled"]) : toset([])
  depends_on = [kubernetes_namespace_v1.platform]

  providers = {
    zitadel    = zitadel
    kubernetes = kubernetes
    random     = random
  }

  org_id       = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org["enabled"].ids[0] : ""
  project_name = "vault"
  app_name     = "vault"
  issuer_url   = "https://${local.platform.services.zitadel.external_domain}"

  # Vault's UI takes the OIDC provider's redirect under either of two
  # callback paths depending on the launch route. Register both so the
  # exact URL Vault sends matches in either case.
  redirect_uris = [
    "https://${local.platform.services.vault.hostname}/ui/vault/auth/oidc/oidc/callback",
    "https://${local.platform.services.vault.hostname}/oidc/callback",
  ]
  # Vault doesn't drive a post-logout redirect anywhere meaningful;
  # keep the list empty.
  post_logout_uris = []
  # Operator-side k8s Secret destination — lands in `platform`
  # namespace alongside other zitadel-app secrets, but Vault itself
  # consumes the OIDC creds via vco's CR-managed Secret in vco's
  # namespace (see module.vault). This Secret stays as the canonical
  # record of which OIDC client Vault is wired to.
  secret_namespace = kubernetes_namespace_v1.platform.metadata[0].name
  secret_name      = "vault-zitadel-oidc"
  # Vault doesn't envFrom — vco's CR-managed Secret carries the
  # client_id / client_secret in its own shape. Skip every prefab
  # format; the canonical Secret here is just an audit record of
  # which Zitadel client backs Vault.
  secret_formats = []

  # Project roles users get granted to land on a Vault policy at
  # OIDC sign-in. Engine emits one `tenant_<slug>` per project
  # namespace + a single `operator` role for full Vault admin.
  # Operator assigns the relevant role to a Zitadel user via the
  # Zitadel UI (Project → Roles → Grant), and the role key shows up
  # in `urn:zitadel:iam:org:project:roles` claim at login. Vault's
  # JWTOIDCAuthEngineRole CRs (in modules/vault) bound_claims match
  # against these keys.
  # `distinct()` because `local.projects` is keyed `<slug>-<env>` —
  # multi-env projects (e.g. ipsupport-us in prod/dev/mm-dev) repeat
  # the same slug; without dedup `for_each` in modules/zitadel-app
  # crashes with "Duplicate object key".
  roles = concat(
    [{ key = "operator", display_name = "Vault Operator (full admin)" }],
    [for slug in sort(distinct([for p in values(local.projects) : p.slug])) :
      { key = "tenant_${replace(slug, "-", "_")}", display_name = "Vault Tenant — ${slug}" }
    ],
  )
}

module "vault" {
  source     = "./modules/vault"
  depends_on = [module.addons, kubernetes_namespace_v1.platform]

  context          = module.platform_label.context
  enabled          = local.platform.services.vault.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  hostname         = local.platform.services.vault.hostname
  volume_base_path = var.host_volume_path

  # Phase 2 — OIDC self-serve. Wired only when both Vault AND Zitadel
  # are on; otherwise the module stays in Phase 1 shape (root-token
  # only). Tenant list = every project namespace's slug — engine
  # automatically gives every tenant a Vault path/policy/OIDC role
  # (the role is dormant until the operator grants the matching
  # `vault:tenant:<slug>` Zitadel project role to a user; nothing
  # consumes the per-tenant `secret/data/tenants/<slug>/*` path until
  # something is `vault kv put`'d there).
  oidc_enabled       = local.platform.services.vault.enabled && local.platform.services.zitadel.enabled
  oidc_issuer_url    = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  oidc_client_id     = local.platform.services.vault.enabled && local.platform.services.zitadel.enabled ? module.vault_oidc["enabled"].client_id : ""
  oidc_client_secret = local.platform.services.vault.enabled && local.platform.services.zitadel.enabled ? module.vault_oidc["enabled"].client_secret : ""
  # `distinct()` per the same reason the `roles` list above — multi-
  # env projects share a slug; vault module's `for_each` over tenants
  # would otherwise crash on the duplicates.
  tenants = sort(distinct([for p in values(local.projects) : p.slug]))

  # Phase 2 — VSO. Tied to vault.enabled (no separate config knob;
  # VSO is part of the Vault story — installing it without Vault
  # makes no sense, and operating Vault without it leaves the
  # engine's vault_path mode broken).
  vso_enabled = local.platform.services.vault.enabled
}
