locals {
  # Generic, app-agnostic alert rules every cluster wants. Operators ADD
  # app-specific rules via `services.logging.alert_rules` (merged on top), so
  # the operator config only lists additions — not this baseline. The window
  # lives in the query's `_time:` filter, the threshold in `| filter`.
  _default_alert_rules = {
    critical-log-pattern = {
      query   = "_time:10m (panic OR fatal OR segfault OR \"OOMKilled\" OR \"out of memory\") | stats count() as hits | filter hits:>0"
      for     = "1m"
      summary = "{{ $value }} critical log line(s) (panic/fatal/OOM) cluster-wide in 10m"
    }
  }
}

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

  # Generic baseline rules + the operator's app-specific additions.
  alert_rules = merge(local._default_alert_rules, local.platform.services.logging.alert_rules)
}
