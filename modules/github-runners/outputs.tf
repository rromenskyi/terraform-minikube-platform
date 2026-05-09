output "controller_namespace" {
  description = "Namespace where the ARC controller is installed. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace_controller : ""
}

output "scale_set_names" {
  description = "List of installed scale set names (matches operator-configured map keys). Empty when disabled or no scale sets configured."
  value       = [for k, _ in local.scale_set_targets : k]
}
