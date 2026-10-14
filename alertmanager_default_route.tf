# Delivery for the built-in alerts (kube-prometheus-stack rules: nodes not
# ready, crash-looping pods, failing jobs, Alertmanager itself, ...).
#
# The chart routes everything to a `null` receiver; only the per-namespace
# AlertmanagerConfigs (metric alerts, alertmanager_metric_email.tf) and the
# log alerts (modules/logging) reach anyone. With
# `monitoring.route_builtin_alerts`, a route at the end of the root route
# sends every other warning/critical alert to e-mail, plus the push channel
# (`monitoring.alert_push_url`) when set.
#
# The operator places AlertmanagerConfig routes first, with `continue: true`,
# so alerts they handle reach this route too. It therefore excludes
# `alert_source` metric/log, or those would arrive twice. `info` alerts and
# the always-firing `Watchdog` stay on `null`.
#
# The push URL is mounted from a Secret and read with `url_file`, so the
# topic never appears in the chart values, the Helm release or a plan.

locals {
  _builtin_alerts_on = try(local.platform.monitoring.route_builtin_alerts, false) && local._metric_alert_to != ""
  _builtin_push_on   = local._builtin_alerts_on && local._alert_push_url != ""
  _builtin_push_name = "platform-alert-push"

  alertmanager_builtin_route_values = local._builtin_alerts_on ? {
    config = {
      route = {
        receiver        = "null"
        group_by        = ["namespace"]
        group_wait      = "30s"
        group_interval  = "5m"
        repeat_interval = "12h"
        routes = [
          { receiver = "null", matchers = ["alertname = \"Watchdog\""] },
          {
            receiver        = "platform-builtin"
            matchers        = ["alert_source !~ \"metric|log\"", "severity =~ \"warning|critical\""]
            group_by        = ["alertname", "namespace"]
            repeat_interval = "12h"
          },
        ]
      }
      receivers = [
        { name = "null" },
        merge({
          name = "platform-builtin"
          email_configs = [{
            to            = local._metric_alert_to
            from          = try(local._metric_alert.from, "alerts@example.com")
            hello         = try(local._metric_alert.hello, "alertmanager.example.com")
            smarthost     = try(local._metric_alert.smarthost, "stalwart-smtp.mail.svc.cluster.local:25")
            require_tls   = false
            send_resolved = true
          }]
          }, local._builtin_push_on ? {
          webhook_configs = [{
            url_file      = "/etc/alertmanager/secrets/${local._builtin_push_name}/url"
            send_resolved = true
            max_alerts    = 3 # push message size limit; e-mail has the full list
          }]
        } : {}),
      ]
    }
  } : {}

  # alertmanagerSpec additions, merged with the externalUrl in main.tf.
  alertmanager_builtin_spec = local._builtin_push_on ? { secrets = [local._builtin_push_name] } : {}
}

resource "kubernetes_secret_v1" "alertmanager_push" {
  for_each = local._builtin_push_on ? toset(["enabled"]) : toset([])

  # The namespace comes with the monitoring stack (module.addons).
  depends_on = [module.addons]

  metadata {
    name      = local._builtin_push_name
    namespace = "monitoring"
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  data = {
    url = local._alert_push_url
  }
}
