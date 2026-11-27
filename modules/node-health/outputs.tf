output "taint_key" {
  description = "Key of the NoSchedule taint a node gets while its kernel has hung tasks, for tolerations of workloads that must still run there. Null when the module is disabled."
  value       = var.enabled ? local.taint_key : null
}

output "namespace" {
  description = "Namespace node-problem-detector and node-readiness-controller run in. Empty when the module is disabled."
  value       = var.enabled ? var.namespace : ""
}
