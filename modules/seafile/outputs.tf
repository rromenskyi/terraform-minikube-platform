output "namespace" {
  description = "Namespace Seafile resources land in. Empty when the module is disabled."
  value       = var.enabled ? var.namespace : ""
}

output "service_name" {
  description = "Cluster-internal Service name for Seafile (Seahub on :80, fileserver on :8082). Empty when disabled."
  value       = var.enabled ? "seafile" : ""
}

output "admin_email" {
  description = "Bootstrap super-user email — useful for operator's cheatsheet."
  value       = var.enabled ? var.admin_email : ""
}

output "admin_password" {
  description = "Sensitive — bootstrap super-user password. Surface with `terraform output -raw seafile_admin_password`. Ignored after first boot — Seahub UI rotates the actual stored value."
  value       = var.enabled ? random_password.admin["enabled"].result : ""
  sensitive   = true
}

output "external_url" {
  description = "Public URL operator's clients hit. Empty when disabled."
  value       = var.enabled ? "https://${var.external_hostname}" : ""
}
