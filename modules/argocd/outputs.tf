output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace Argo CD lives in. Null when disabled."
}

output "service_name" {
  value       = var.enabled ? "argocd-server" : null
  description = "ClusterIP Service name for the Argo CD UI/API. Wired into a `kind: external` component yaml so the IngressRoute pipeline routes the public hostname here. Null when disabled."
}

output "service_port" {
  value       = var.enabled ? 80 : null
  description = "Service port the IngressRoute should target. Null when disabled."
}
