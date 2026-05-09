output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Ollama is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.ollama : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "Ollama in-cluster hostname, or null if disabled."
}

output "url" {
  value       = one([for s in kubernetes_service_v1.ollama : "http://${s.metadata[0].name}.${var.namespace}.svc.cluster.local:11434"])
  description = "Ollama in-cluster URL — drop straight into OLLAMA_HOST. Null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.ollama : s.metadata[0].name])
  description = "Ollama Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.ollama : s.spec[0].port[0].port])
  description = "Ollama Service port, or null if disabled."
}

output "models" {
  value       = var.enabled ? var.models : []
  description = "Models pre-pulled by this module (empty list if disabled)."
}
