# Samba file server for the LAN (modules/samba). Off by default;
# `services.samba` in config/platform.yaml. See modules/samba/README.md.

module "samba" {
  source     = "./modules/samba"
  depends_on = [module.addons, module.metallb, module.piraeus, module.vault]

  context          = module.platform_label.context
  enabled          = local.platform.services.samba.enabled
  namespace        = local.platform.services.samba.namespace
  image            = local.platform.services.samba.image
  storage_class    = local.platform.services.samba.storage_class
  size             = local.platform.services.samba.size
  node_hostnames   = local.platform.services.samba.node_hostnames
  load_balancer_ip = local.platform.services.samba.load_balancer_ip
  address_pool     = local.platform.services.samba.address_pool
  allowed_networks = local.platform.services.samba.allowed_networks
  users            = local.platform.services.samba.users
  vault_path       = local.platform.services.samba.vault_path
  # Narrow Vault role from module.vault (vso_platform_readers): this path only.
  vault_auth_role  = local.platform.services.vault.enabled ? "vso-platform-samba" : ""
  shares           = local.platform.services.samba.shares
  seed             = local.platform.services.samba.seed
  seed_image       = local.platform.services.samba.seed_image
  failover_seconds = local.platform.services.samba.failover_seconds
}
