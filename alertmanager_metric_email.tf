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
# list) comes from the gitignored config under `monitoring.metric_alert_email`
# — tracked TF stays generic. smarthost defaults to the in-cluster Stalwart
# inbound listener (unauthenticated LOCAL delivery), same path the log alerts
# already use. Absent config (no address or no namespaces) => no resources.
locals {
  _metric_alert     = try(local.platform.monitoring.metric_alert_email, {})
  _metric_alert_nss = try(local._metric_alert.namespaces, [])
  _metric_alert_to  = try(local._metric_alert.address, "")
  _metric_alert_on  = local._metric_alert_to != "" && length(local._metric_alert_nss) > 0
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
        receiver       = "email"
        groupBy        = ["alertname", "namespace"]
        groupWait      = "30s"
        groupInterval  = "5m"
        repeatInterval = "3h"
        matchers       = [{ name = "alert_source", value = "metric", matchType = "=" }]
      }
      receivers = [{
        name = "email"
        emailConfigs = [{
          to           = local._metric_alert_to
          from         = try(local._metric_alert.from, "alerts@example.com")
          hello        = try(local._metric_alert.hello, "alertmanager.example.com")
          smarthost    = try(local._metric_alert.smarthost, "stalwart-smtp.mail.svc.cluster.local:25")
          requireTLS   = false
          sendResolved = true
        }]
      }]
    }
  })
}
