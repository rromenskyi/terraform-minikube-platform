# Operator-defined Prometheus alert rules.
#
# kube-prometheus-stack (module.addons) owns Prometheus + Alertmanager. Its
# Prometheus CR selects PrometheusRules by the label `release:
# kube-prometheus-stack`, cluster-wide. This renders ONE PrometheusRule from
# the operator's gitignored config so app/tenant-specific PromQL never lands in
# tracked TF (same split as `services.logging.alert_rules` for log alerts).
#
# Config shape (config/platform.yaml, gitignored):
#   monitoring:
#     prometheus_rules:
#       <group-name>:
#         - alert: <Name>
#           expr: <PromQL>
#           for: 2m                 # optional
#           labels: { severity: critical }      # optional
#           annotations: { summary: "...", description: "..." }  # optional
#
# Empty/absent config => no resource (count 0), so this is a no-op for any
# cluster that doesn't declare rules. Lands in the `monitoring` namespace so it
# matches the Prometheus rule selector regardless of its namespaceSelector.
locals {
  _prometheus_rule_groups = try(local.platform.monitoring.prometheus_rules, {})
}

resource "kubectl_manifest" "operator_prometheus_rules" {
  count      = length(local._prometheus_rule_groups) > 0 ? 1 : 0
  depends_on = [module.addons]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "platform-operator-rules"
      namespace = "monitoring"
      labels = {
        release                        = "kube-prometheus-stack"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      groups = [
        for name, rules in local._prometheus_rule_groups : {
          name  = name
          rules = rules
        }
      ]
    }
  })
}
