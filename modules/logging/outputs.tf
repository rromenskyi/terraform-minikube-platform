output "enabled" {
  description = "Whether the logging stack is deployed."
  value       = var.enabled
}

output "victorialogs_url" {
  description = "In-cluster VictoriaLogs HTTP endpoint (ingest + LogsQL query API). Null when disabled. Consumed by a future vmalert datasource + as the Grafana datasource URL."
  value       = var.enabled ? "http://${local.vl_name}.${var.namespace}.svc.cluster.local:9428" : null
}

output "namespace" {
  description = "Namespace the stack runs in."
  value       = var.namespace
}
