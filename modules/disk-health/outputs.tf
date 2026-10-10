output "namespace" {
  description = "Namespace the SMART exporter runs in. Empty when the module is disabled."
  value       = var.enabled ? var.namespace : ""
}

output "dashboard_uid" {
  description = "Grafana uid of the disk health dashboard, for links from alerts or other dashboards. Null when the dashboard is not emitted."
  value       = var.enabled && var.grafana_dashboard_enabled ? "disk-health" : null
}
