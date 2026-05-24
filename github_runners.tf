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
  description = "List of installed runner scale set names. Empty when disabled or no scale sets configured. Retained for backward compatibility — prefer `github_runners_scale_set_info` or the aggregated `platform_connection_info.github_runners` for new consumers (richer schema, includes the `runs-on:` label and config URL needed to wire workflows)."
  value       = module.github_runners.scale_set_names
}

output "github_runners_scale_set_info" {
  description = "Map of installed runner scale sets with the non-secret coordinates a downstream consumer (workflow files in other repos, sibling Terraform stacks) needs to wire CI without grepping platform.yaml. Keyed by scale-set name. Values include `runs_on_label`, `github_config_url`, `namespace`, `min_runners`, `max_runners`. Schema is additive — new fields may appear without notice, existing fields are stable. Also surfaced inside `platform_connection_info.github_runners` for consumers that want one aggregated entry point."
  value       = module.github_runners.scale_sets
}
