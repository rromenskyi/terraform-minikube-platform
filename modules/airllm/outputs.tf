output "namespace" {
  description = "Namespace the gateway runs in, or null if disabled."
  value       = one([for n in kubernetes_namespace_v1.this : n.metadata[0].name])
}

output "service" {
  description = "In-cluster Service coordinates of the gateway (`name`, `namespace`, `port`), or null if disabled."
  value       = var.enabled ? { name = var.name, namespace = var.namespace, port = 8080 } : null
}

output "url" {
  description = "Public base URL, or null without a hostname."
  value       = var.enabled && var.hostname != "" ? "https://${var.hostname}" : null
}

output "master_key" {
  description = "Base64 master key the instance encrypts provider credentials with. Another instance seeded from this one's database needs it as its `master_key`."
  value       = var.enabled ? local.master_key : null
  sensitive   = true
}
