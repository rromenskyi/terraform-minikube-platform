output "local_ip" {
  description = "Link-local address the cache answers on, next to the cluster DNS Service address. Null if disabled."
  value       = var.enabled ? var.local_ip : null
}

output "corefile" {
  description = "Rendered Corefile base (before the node-cache binary fills in the upstream addresses). Null if disabled."
  value       = var.enabled ? local.corefile : null
}
