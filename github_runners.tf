# GitHub self-hosted runners — Actions Runner Controller (ARC v0.9+).
#
# Modern ARC has a built-in listener that polls the GitHub Actions
# API and scales runner pods 0 → max_runners as the queue grows. No
# KEDA needed. The earlier KEDA-based ARC (`actions-runner-controller`
# from `summerwind`) is deprecated; this module uses the
# GitHub-maintained `actions/actions-runner-controller` charts only.
#
# Operator drives layout via `services.github_runners.scale_sets` —
# each entry is one runner pool (org / repo / enterprise). The
# engine carries no GitHub URLs, no PATs, no per-set names: every
# operator-specific value lives in `config/platform.yaml`.

module "github_runners" {
  source     = "./modules/github-runners"
  depends_on = [module.addons]

  context                  = module.platform_label.context
  enabled                  = local.platform.services.github_runners.enabled
  controller_node_selector = local.platform.services.github_runners.controller_node_selector
  controller_tolerations   = local.platform.services.github_runners.controller_tolerations
  scale_sets               = local.platform.services.github_runners.scale_sets
  tokens                   = var.github_runner_tokens
}

output "github_runners_scale_sets" {
  description = "List of installed runner scale set names. Empty when disabled or no scale sets configured."
  value       = module.github_runners.scale_set_names
}
