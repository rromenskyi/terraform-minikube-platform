output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Longhorn namespace, null when disabled."
}

output "storage_class" {
  value       = var.enabled ? "longhorn" : null
  description = "StorageClass name to set on PVCs that should land on Longhorn-managed volumes. The chart creates the class itself; this output is just a stable reference for callers."
}

output "backup_target" {
  value       = local.backup_configured ? local.backup_target_url : null
  description = "Longhorn S3 backup target URL, or null when backup is unconfigured."
}
