output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where the dashboard lives. Null when disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.this : s.metadata[0].name])
  description = "ClusterIP Service name (for IngressRoute target). Null when disabled."
}

output "service_port" {
  value       = local.port_service
  description = "Service port the IngressRoute should target."
}

output "service_account_name" {
  value       = one([for s in kubernetes_service_account_v1.this : s.metadata[0].name])
  description = "ServiceAccount name. Null when disabled."
}
