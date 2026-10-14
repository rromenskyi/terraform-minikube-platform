# Email routing for metric alerts (label `alert_source=metric`).
#
# kube-prometheus-stack's Alertmanager selects AlertmanagerConfigs cluster-wide
# but its default `OnNamespace` matcher strategy injects a `namespace=<config's
# own namespace>` matcher into each. Metric alerts carry the namespace of the
# series they fire on (e.g. an engine in a project namespace), NOT `monitoring`
# — so the log-alert AlertmanagerConfig (in the logging namespace) can't catch
# them. This emits one AlertmanagerConfig per namespace the operator lists, each
# routing that namespace's `alert_source=metric` alerts to email.
#
# Everything operator/tenant-specific (recipient, From, EHLO, the namespace
# list, optional `repeat_intervals` per namespace) comes from the gitignored
# config under `monitoring.metric_alert_email`
# — tracked TF stays generic. smarthost defaults to the in-cluster Stalwart
# inbound listener (unauthenticated LOCAL delivery), same path the log alerts
# already use. Absent config (no address or no namespaces) => no resources.
locals {
  _metric_alert     = try(local.platform.monitoring.metric_alert_email, {})
  _metric_alert_nss = try(local._metric_alert.namespaces, [])
  _metric_alert_to  = try(local._metric_alert.address, "")
  _metric_alert_on  = local._metric_alert_to != "" && length(local._metric_alert_nss) > 0
}

# Optional push channel next to e-mail (`monitoring.alert_push_url`, e.g.
# ntfy with `?template=alertmanager`), kept in a Secret in each namespace
# because an AlertmanagerConfig can only reference its own namespace and a
# push topic name works like a password.
resource "kubernetes_secret_v1" "metric_alert_push" {
  for_each = local._metric_alert_on && try(local.platform.monitoring.alert_push_url, "") != "" ? toset(local._metric_alert_nss) : toset([])

  metadata {
    name      = "metric-alerts-push"
    namespace = each.value
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  data = {
    url = local.platform.monitoring.alert_push_url
  }
}

resource "kubectl_manifest" "metric_alert_email" {
  for_each   = local._metric_alert_on ? toset(local._metric_alert_nss) : toset([])
  depends_on = [module.addons]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1alpha1"
    kind       = "AlertmanagerConfig"
    metadata = {
      name      = "metric-alerts-email"
      namespace = each.value
      labels    = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      route = {
        receiver      = "email"
        groupBy       = ["alertname", "namespace"]
        groupWait     = "30s"
        groupInterval = "5m"
        # Optional per-namespace override, e.g. a weekly reminder for
        # long-lived findings while new ones still notify at once.
        repeatInterval = try(local._metric_alert.repeat_intervals[each.value], "3h")
        matchers       = [{ name = "alert_source", value = "metric", matchType = "=" }]
      }
      # Alertmanager fires every integration of a matched receiver, so the
      # push webhook adds to the e-mail, never replaces it.
      receivers = [merge({
        name = "email"
        emailConfigs = [{
          to           = local._metric_alert_to
          from         = try(local._metric_alert.from, "alerts@example.com")
          hello        = try(local._metric_alert.hello, "alertmanager.example.com")
          smarthost    = try(local._metric_alert.smarthost, "stalwart-smtp.mail.svc.cluster.local:25")
          requireTLS   = false
          sendResolved = true
        }]
        }, contains(keys(kubernetes_secret_v1.metric_alert_push), each.value) ? {
        webhookConfigs = [{
          urlSecret    = { name = kubernetes_secret_v1.metric_alert_push[each.value].metadata[0].name, key = "url" }
          sendResolved = true
        }]
      } : {})]
    }
  })
}
