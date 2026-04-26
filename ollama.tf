# Shared Ollama instance for all projects.
# Models cached once on the platform hostPath volume and served to every
# tenant through the in-cluster Service. Ollama has no native auth, so
# cluster-internal access is trust-based (same trust boundary that lets
# tenants share Redis/MySQL). Public access is an `ollama` external
# component away — set `basic_auth: true` on it for edge protection.
#
# Toggle via `services.ollama` in `config/platform.yaml`. Deployed into
# the shared `platform` namespace owned by root-level `platform.tf`.
module "ollama" {
  source     = "./modules/ollama"
  depends_on = [module.addons]

  enabled          = local.platform.services.ollama.enabled
  namespace        = kubernetes_namespace_v1.platform.metadata[0].name
  volume_base_path = var.host_volume_path

  # Pulled straight from config/platform.yaml.services.ollama.* —
  # models + pod-level resources live in YAML so flipping hardware
  # doesn't touch terraform code.
  models         = local.platform.services.ollama.models
  memory_request = local.platform.services.ollama.memory_request
  memory_limit   = local.platform.services.ollama.memory_limit
  cpu_request    = local.platform.services.ollama.cpu_request
  cpu_limit      = local.platform.services.ollama.cpu_limit

  # Optional GPU offload. Whole `gpu:` block in platform.yaml is passed
  # through verbatim. Null (the default) keeps the StatefulSet on its
  # CPU-only image and unprivileged pod spec. See `var.gpu` in
  # `modules/ollama/main.tf` for the expected object shape and the
  # operator-supplied keys (image, device_path, supplemental_groups,
  # env). Module bakes in nothing vendor- or hardware-specific.
  gpu = local.platform.services.ollama.gpu
}
