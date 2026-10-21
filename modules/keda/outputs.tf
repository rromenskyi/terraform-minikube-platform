output "namespace" {
  description = "Namespace KEDA is installed in. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace : ""
}
