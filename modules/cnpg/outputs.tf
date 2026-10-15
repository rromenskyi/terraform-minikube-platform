output "cluster_name" {
  description = "Name of the CloudNativePG Cluster, or null if disabled."
  value       = one([for c in kubectl_manifest.cluster : var.name])
}

output "replica_cluster_name" {
  description = "Name of the second Cluster (`replica_cluster`), or null without one."
  value       = one([for c in kubectl_manifest.replica_cluster : local.replica_name])
}

output "primary_cluster" {
  description = "The Cluster that takes writes (`primary_cluster`, defaulting to the main cluster), or null if disabled."
  value       = var.enabled ? local.primary_cluster : null
}

output "host" {
  description = "In-cluster hostname that always points at the current primary: `service_name` when set, else the operator's `<primary_cluster>-rw`. Null if disabled."
  value       = var.enabled ? "${var.service_name != "" ? var.service_name : "${local.primary_cluster}-rw"}.${var.namespace}.svc.cluster.local" : null
}

output "ro_host" {
  description = "In-cluster hostname of the read-only Service (replicas only) of `primary_cluster`. Null if disabled."
  value       = var.enabled ? "${local.primary_cluster}-ro.${var.namespace}.svc.cluster.local" : null
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
