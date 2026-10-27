# Weekly report of Prometheus metric families that nothing uses.
#
# scripts/metrics-usage-report.py compares the series in Prometheus with the
# metric names its loaded rules and the Grafana dashboards (ConfigMaps
# labelled `grafana_dashboard`) reference, prints every unused family with at
# least `min_series` series to the Job's log, and, when there is any, sends
# one e-mail through the same SMTP relay and address as the metric alerts
# (`monitoring.metric_alert_email`). Dropping a family is a decision, made
# at the scrape in a PR; the report only finds the candidates.
#
# Config (`monitoring.metrics_usage_report`, gitignored):
#   enabled:    true
#   schedule:   "0 15 * * 1"   # UTC, Mondays
#   min_series: 1000           # smaller families are not worth a mention
#   top:        20             # families listed in the e-mail
#
# Reading the dashboards needs list on ConfigMaps cluster-wide (dashboards
# live in several namespaces); the ServiceAccount gets nothing else.

locals {
  metrics_usage_report = merge({
    enabled    = false
    schedule   = "0 15 * * 1"
    min_series = 1000
    top        = 20
  }, try(local.platform.monitoring.metrics_usage_report, {}))

  metrics_usage_report_set  = local.metrics_usage_report.enabled ? toset(["enabled"]) : toset([])
  metrics_usage_report_name = "metrics-usage-report"
}

resource "kubernetes_config_map_v1" "metrics_usage_report" {
  for_each = local.metrics_usage_report_set

  depends_on = [module.addons]

  metadata {
    name      = local.metrics_usage_report_name
    namespace = "monitoring"
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = local.metrics_usage_report_name })
  }

  data = {
    "report.py" = file("${path.module}/scripts/metrics-usage-report.py")
  }
}

resource "kubernetes_service_account_v1" "metrics_usage_report" {
  for_each = local.metrics_usage_report_set

  depends_on = [module.addons]

  metadata {
    name      = local.metrics_usage_report_name
    namespace = "monitoring"
    labels    = module.platform_label.tags
  }
}

resource "kubernetes_cluster_role_v1" "metrics_usage_report" {
  for_each = local.metrics_usage_report_set

  metadata {
    name   = local.metrics_usage_report_name
    labels = module.platform_label.tags
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "metrics_usage_report" {
  for_each = local.metrics_usage_report_set

  metadata {
    name   = local.metrics_usage_report_name
    labels = module.platform_label.tags
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.metrics_usage_report["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.metrics_usage_report["enabled"].metadata[0].name
    namespace = "monitoring"
  }
}

resource "kubernetes_cron_job_v1" "metrics_usage_report" {
  for_each = local.metrics_usage_report_set

  metadata {
    name      = local.metrics_usage_report_name
    namespace = "monitoring"
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = local.metrics_usage_report_name })
  }

  spec {
    schedule                      = local.metrics_usage_report.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 2
    starting_deadline_seconds     = 3600

    job_template {
      metadata {
        labels = merge(module.platform_label.tags, { "app.kubernetes.io/component" = local.metrics_usage_report_name })
      }

      spec {
        # A failed report is retried next week, not in a loop.
        backoff_limit              = 0
        ttl_seconds_after_finished = 604800 # keep the log for a week

        template {
          metadata {
            labels = merge(module.platform_label.tags, { "app.kubernetes.io/component" = local.metrics_usage_report_name })
            annotations = {
              "checksum/report-py" = sha256(file("${path.module}/scripts/metrics-usage-report.py"))
            }
          }

          spec {
            restart_policy       = "Never"
            service_account_name = kubernetes_service_account_v1.metrics_usage_report["enabled"].metadata[0].name

            security_context {
              run_as_user     = 65534
              run_as_non_root = true
              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            container {
              name    = "report"
              image   = "python:3.14-slim@sha256:82abc9f53600280b0757126f83c5a7d47088592d2acb6b4c0b9e97f76865508c"
              command = ["python3", "/app/report.py"]

              env {
                name  = "PROMETHEUS_URL"
                value = "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"
              }
              env {
                name  = "MIN_SERIES"
                value = tostring(local.metrics_usage_report.min_series)
              }
              env {
                name  = "TOP"
                value = tostring(local.metrics_usage_report.top)
              }
              env {
                name  = "REPORT_TO"
                value = local._metric_alert_to
              }
              env {
                name  = "REPORT_FROM"
                value = try(local._metric_alert.from, "")
              }
              env {
                name  = "SMARTHOST"
                value = try(local._metric_alert.smarthost, "stalwart-smtp.mail.svc.cluster.local:25")
              }
              env {
                name  = "HELO"
                value = try(local._metric_alert.hello, "")
              }
              env {
                name  = "PYTHONDONTWRITEBYTECODE"
                value = "1"
              }

              volume_mount {
                name       = "script"
                mount_path = "/app"
                read_only  = true
              }

              resources {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { cpu = "500m", memory = "256Mi" }
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                capabilities {
                  drop = ["ALL"]
                }
              }
            }

            volume {
              name = "script"
              config_map {
                name         = kubernetes_config_map_v1.metrics_usage_report["enabled"].metadata[0].name
                default_mode = "0444"
              }
            }
          }
        }
      }
    }
  }
}
