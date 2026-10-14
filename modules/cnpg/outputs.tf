output "cluster_name" {
  description = "Name of the CloudNativePG Cluster, or null if disabled."
  value       = one([for c in kubectl_manifest.cluster : var.name])
}

output "host" {
  description = "In-cluster hostname that always points at the current primary: `service_name` when set, else the operator's `<name>-rw`. Null if disabled."
  value       = var.enabled ? "${var.service_name != "" ? var.service_name : "${var.name}-rw"}.${var.namespace}.svc.cluster.local" : null
}

output "ro_host" {
  description = "In-cluster hostname of the read-only Service (replicas only). Null if disabled."
  value       = var.enabled ? "${var.name}-ro.${var.namespace}.svc.cluster.local" : null
}

output "port" {
  description = "Postgres port, or null if disabled."
  value       = var.enabled ? 5432 : null
}

output "superuser_secret_name" {
  description = "Secret in the cluster's namespace with the `postgres` superuser credentials (`username` / `password`). Null if disabled."
  value       = one([for s in kubernetes_secret_v1.superuser : s.metadata[0].name])
}

output "backup_destination" {
  description = "Object-store path the WAL archive and base backups go to, or null when backups are off."
  value       = local.backup_configured ? "s3://${var.backup_bucket}/${var.backup_prefix}/${var.name}/" : null
}

output "namespace" {
  description = "Namespace the cluster runs in, or null if disabled."
  value       = var.enabled ? var.namespace : null
}
