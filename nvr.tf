# Cameras recorded by Frigate (modules/nvr, ADR 0021 in the live repo).
module "nvr" {
  source     = "./modules/nvr"
  depends_on = [module.addons, module.piraeus, module.vault]

  context         = module.platform_label.context
  enabled         = local.platform.services.nvr.enabled
  namespace       = local.platform.services.nvr.namespace
  image           = local.platform.services.nvr.image
  storage_class   = local.platform.services.nvr.storage_class
  recordings_size = local.platform.services.nvr.recordings_size
  config_size     = local.platform.services.nvr.config_size
  shm_size        = local.platform.services.nvr.shm_size
  cache_size      = local.platform.services.nvr.cache_size
  resources       = local.platform.services.nvr.resources
  quota           = local.platform.services.nvr.quota
  node_selector   = local.platform.services.nvr.node_selector
  tolerations     = local.platform.services.nvr.tolerations
  vault_path      = local.platform.services.nvr.vault_path
  # Narrow Vault role from module.vault (vso_platform_readers): this path only.
  vault_auth_role = local.platform.services.vault.enabled ? "vso-platform-nvr" : ""
  frigate_config  = local.platform.services.nvr.frigate_config
}
