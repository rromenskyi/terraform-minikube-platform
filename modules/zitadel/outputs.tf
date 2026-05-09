output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Zitadel runs, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.zitadel : s.metadata[0].name])
  description = "In-cluster Service name for Zitadel."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.zitadel : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "In-cluster FQDN for Zitadel."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.zitadel : s.spec[0].port[0].port])
  description = "Service port (HTTP, plain — TLS terminates at Cloudflare)."
}

output "external_domain" {
  value       = var.enabled ? var.external_domain : null
  description = "Public hostname Zitadel issues tokens for."
}

output "admin_username" {
  value       = var.enabled ? var.first_admin_username : null
  description = "Bootstrap human admin username — only meaningful right after first apply."
}

output "admin_password" {
  value       = one([for p in random_password.admin : p.result])
  sensitive   = true
  description = "Bootstrap human admin password. Change in the UI on first login. Only re-emitted if the random_password resource is replaced."
}
