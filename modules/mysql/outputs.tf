output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where MySQL is deployed, or null if the module is disabled."
}

output "host" {
  value = one([
    for s in kubernetes_service_v1.mysql :
    "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"
  ])
  description = "MySQL in-cluster hostname, or null if the module is disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.mysql : s.metadata[0].name])
  description = "MySQL Service name, or null if the module is disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.mysql : s.spec[0].port[0].port])
  description = "MySQL Service port, or null if the module is disabled."
}

output "root_password" {
  value       = one([for p in random_password.root : p.result])
  sensitive   = true
  description = "MySQL root password (also in the mysql-root Secret), or null if the module is disabled."
}

output "root_secret_name" {
  value       = one([for s in kubernetes_secret_v1.mysql_root : s.metadata[0].name])
  description = "Name of the Secret carrying MYSQL_ROOT_PASSWORD. Consumed by the backup module's cross-namespace mirror Secret. Null when disabled."
}
