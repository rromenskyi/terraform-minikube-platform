output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where PostgreSQL is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.postgres : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "PostgreSQL in-cluster hostname, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.postgres : s.metadata[0].name])
  description = "PostgreSQL Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.postgres : s.spec[0].port[0].port])
  description = "PostgreSQL Service port, or null if disabled."
}

output "superuser_password" {
  value       = one([for p in random_password.superuser : p.result])
  sensitive   = true
  description = "Password for the `postgres` superuser (also in the postgres-superuser Secret). Null if disabled."
}

output "superuser_secret_name" {
  value       = one([for s in kubernetes_secret_v1.superuser : s.metadata[0].name])
  description = "Name of the Secret holding the superuser password. The tenant-provisioner Job reads it when creating per-tenant DBs. Null if disabled."
}
