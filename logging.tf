# Cluster log aggregation — VictoriaLogs (store/query) + Vector (collector) +
# a Grafana datasource. Lands in the `monitoring` namespace next to the
# kube-prometheus-stack so the Grafana datasource sidecar discovers the
# emitted ConfigMap. The VictoriaLogs Grafana plugin is installed through the
# addons module (`monitoring_grafana_extra_values`, in main.tf) gated on this
# service being enabled. Toggle via `services.logging` in config/platform.yaml.
module "logging" {
  source     = "./modules/logging"
  depends_on = [module.addons]

  context   = module.platform_label.context
  enabled   = local.platform.services.logging.enabled
  namespace = local.platform.services.logging.namespace

  retention_period = local.platform.services.logging.retention_period
  storage_class    = local.platform.services.logging.storage_class
  storage_size     = local.platform.services.logging.storage_size
  node_selector    = local.platform.services.logging.node_selector

  # Alerting — empty alert_email leaves the store + collector running with no
  # vmalert / Alertmanager receiver. Set it to wire LogsQL rule alerts to email
  # via the existing Alertmanager + the in-cluster Stalwart SMTP (local mailbox).
  alert_email = local.platform.services.logging.alert_email
}
