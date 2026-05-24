output "controller_namespace" {
  description = "Namespace where the ARC controller is installed. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace_controller : ""
}

output "scale_set_names" {
  description = "List of installed scale set names (matches operator-configured map keys). Empty when disabled or no scale sets configured. Retained for backward compatibility — prefer `scale_sets` for new consumers."
  value       = [for k, _ in local.scale_set_targets : k]
}

output "scale_sets" {
  description = "Map of installed scale sets keyed by scale-set name, with non-secret coordinates downstream consumers need to wire workflow files: `runs_on_label` (string — the second element of `runs-on: [self-hosted, <label>]` in the consuming workflow; matches the scale-set name), `github_config_url` (the org / repo / enterprise URL this scale set registers against), `namespace` (k8s namespace the runner pods land in), `min_runners`, `max_runners`. Empty map when disabled. Schema is informational — consumers MAY read via `data.terraform_remote_state` but the platform engine reserves the right to add fields without notice; downstream PRs should not break on additive changes."
  value = {
    for k, v in local.scale_set_targets : k => {
      runs_on_label     = k
      github_config_url = v.github_config_url
      namespace         = v.namespace
      min_runners       = v.min_runners
      max_runners       = v.max_runners
    }
  }
}
