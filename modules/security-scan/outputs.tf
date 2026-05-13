output "namespace" {
  description = "Namespace trivy-operator + the snapshot CronJob land in. Empty when the module is disabled."
  value       = var.enabled ? var.namespace : ""
}

output "scan_target_namespaces" {
  description = "Allowlist of namespaces the trivy-operator is configured to scan in this release. Empty list when the module is disabled."
  value       = var.enabled ? local.target_namespaces : []
}
