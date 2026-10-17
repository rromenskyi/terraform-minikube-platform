resource "terraform_data" "gpu_dra_checks" {
  lifecycle {
    precondition {
      condition     = !local.platform.services.gpu_dra.enabled || local.platform.services.gpu_dra.driver_name != ""
      error_message = "services.gpu_dra.enabled = true requires services.gpu_dra.driver_name (a DNS subdomain you own, e.g. gpu.example.com)."
    }
  }
}

module "gpu_dra" {
  source = "./modules/gpu-dra"

  enabled         = local.platform.services.gpu_dra.enabled
  namespace       = local.platform.services.gpu_dra.namespace
  image           = local.platform.services.gpu_dra.image
  driver_name     = local.platform.services.gpu_dra.driver_name
  node_selector   = local.platform.services.gpu_dra.node_selector
  vram_reserve    = local.platform.services.gpu_dra.vram_reserve
  rescan_interval = local.platform.services.gpu_dra.rescan_interval
}
