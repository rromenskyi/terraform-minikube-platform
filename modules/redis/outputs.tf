output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Redis is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.redis : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "Redis in-cluster hostname, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.redis : s.metadata[0].name])
  description = "Redis Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.redis : s.spec[0].port[0].port])
  description = "Redis Service port, or null if disabled."
}

output "default_password" {
  value       = one([for p in random_password.default : p.result])
  sensitive   = true
  description = "Password for the built-in `default` Redis user (aka root). Tenants don't get this — each project module provisions its own ACL user. Null if disabled."
}

output "default_secret_name" {
  value       = one([for s in kubernetes_secret_v1.default : s.metadata[0].name])
  description = "Name of the Secret holding the `default`-user password. The tenant-provisioner Job reads it when calling ACL SETUSER. Null if disabled."
}

output "helm_revision" {
  value       = length(local.sentinel_instances) > 0 ? helm_release.valkey_sentinel["enabled"].metadata.revision : 0
  description = "Helm release revision counter for the Valkey/Sentinel chart. Increments on every `helm upgrade` (chart bump, values change, replicas/affinity update, etc). Consumers (tenant ACL provisioner Jobs) interpolate this into their resource name so a chart upgrade — which can switch the master pod and lose previously-applied ACL state — automatically re-runs the ACL setup with the new credentials. Zero when sentinel mode is disabled (no chart deployed). Sentinel-mode-only by design — the legacy single-pod path uses a different bring-up Job that is not affected by master switches."
}
