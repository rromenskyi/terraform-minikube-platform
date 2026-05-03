# Vault community — platform secrets store, replacement for the
# Infisical attempt that hit a paywall on OIDC SSO.
#
# Phase 0 (this PR): module skeleton, raft single-node, hostPath PV,
# init Job, postStart auto-unseal. Operator gets a working Vault UI
# at `https://<hostname>` and a root token via
# `terraform output -raw vault_root_token` for break-glass.
#
# Phase 1 (deferred): Zitadel JWT auth method via the `hashicorp/vault`
# TF provider — `vault_jwt_auth_backend` + `vault_jwt_auth_backend_role`
# mapping Zitadel `vault_admin` / `vault_operator` claims to Vault
# policies. UI login page gets the "Sign in with OIDC" button. Phase 2
# wires the Vault Secrets Operator + first migrated tenant secret.
# See `BACKLOG.md` for the full roadmap.

# Vault has its own internal store (raft), unlike Infisical which
# needed Postgres + Redis. So no infrastructure prereq checks here
# beyond hostname.

check "vault_hostname_set" {
  assert {
    condition     = !local.platform.services.vault.enabled || local.platform.services.vault.hostname != ""
    error_message = "services.vault.hostname must be set when vault is enabled (e.g. `vault.example.com`). Drives the IngressRoute Host(...) match. Add the matching `<prefix>: vault` route to your domain yaml so cloudflared sees the hostname through the same project-IngressRoute pipeline as Stalwart and oauth2-proxy."
  }
}

module "vault" {
  source     = "./modules/vault"
  depends_on = [module.addons, kubernetes_namespace_v1.platform]

  enabled          = local.platform.services.vault.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  hostname         = local.platform.services.vault.hostname
  volume_base_path = var.host_volume_path
}
