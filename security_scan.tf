# Continuous CVE scanning of platform-system images — root wiring.
#
# The module owns the trivy-operator release and its alert rules; findings
# surface as alerts through the platform's Alertmanager (routing labels
# below) and as metrics/Grafana. Operator drives toggle + tuning via
# `services.security_scan` in `config/platform.yaml`.

module "security_scan" {
  source = "./modules/security-scan"

  context = module.platform_label.context

  enabled                      = local.platform.services.security_scan.enabled
  trivy_operator_chart_version = local.platform.services.security_scan.trivy_operator_chart_version
  trivy_operator_crds          = try(data.helm_template.trivy_operator_crds["enabled"].crds, [])
  node_selector                = local.platform.services.security_scan.node_selector
  extra_target_namespaces      = local.platform.services.security_scan.extra_target_namespaces
  service_monitor_enabled      = local.platform.services.security_scan.service_monitor_enabled
  alerts_enabled               = local.platform.services.security_scan.alerts_enabled
  alert_severities             = local.platform.services.security_scan.alert_severities
  grafana_dashboard_enabled    = local.platform.services.security_scan.service_monitor_enabled
  # Metric alerts reach email through alertmanager_metric_email.tf, which
  # matches this label (list the scanner namespace there).
  alert_labels = { alert_source = "metric" }
}
