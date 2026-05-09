output "enabled" {
  description = "Whether the module emitted any resources."
  value       = var.enabled
}

output "endpoint" {
  description = "Cluster-internal S3 API URL. Empty when disabled."
  value       = var.enabled ? local.endpoint : ""
}

output "service_name" {
  description = "Service name for the MinIO API. Empty when disabled."
  value       = var.enabled ? local.service_name : ""
}

output "bucket_secret_names" {
  description = "Map of bucket name → list of `{namespace, secret_name}` for every consumer Secret emitted on that bucket. Empty when no buckets configured or module disabled."
  value       = { for k, v in local.bucket_targets : k => v.consumers }
}
