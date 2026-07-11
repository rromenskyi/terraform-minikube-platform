locals {
  # Generic, app-agnostic alert rules every cluster wants. Operators ADD
  # app-specific rules via `services.logging.alert_rules` (merged on top), so
  # the operator config only lists additions — not this baseline. The window
  # lives in the query's `_time:` filter, the threshold in `| filter`.
  _default_alert_rules = {
    critical-log-pattern = {
      # Grouped by source namespace/pod so the alert email names the offender
      # (a bare cluster-wide count() forced a manual log hunt every time).
      # `rename` gives the fields dot-free names Prometheus-model consumers
      # accept; one alert fires per offending pod.
      query   = "_time:10m (panic OR fatal OR segfault OR \"OOMKilled\" OR \"out of memory\") | rename kubernetes.pod_namespace as src_namespace, kubernetes.pod_name as src_pod | stats by (src_namespace, src_pod) count() as hits | filter hits:>0"
      for     = "1m"
      summary = "{{ $value }} critical log line(s) (panic/fatal/OOM) from {{ $labels.src_namespace }}/{{ $labels.src_pod }} in 10m"
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

  # Browser-reachable base for vmalert's alert Source/generator links (read
  # from the `monitoring:` config block alongside the alertmanager/prometheus
  # external URLs). Empty => vmalert keeps its in-cluster pod-address default.
  vmalert_external_url = try(local.platform.monitoring.vmalert_external_url, "")
}
