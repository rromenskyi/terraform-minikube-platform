output "namespace" {
  description = "Namespace MetalLB is installed in. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace : ""
}

output "pools" {
  description = "Map of pool name → addresses, mirroring the input. Useful for downstream modules that want to assert a pool exists before requesting `loadBalancerIP` from it."
  value       = var.enabled ? { for k, v in var.pools : k => v.addresses } : {}
}
