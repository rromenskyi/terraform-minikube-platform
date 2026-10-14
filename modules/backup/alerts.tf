# Alerting on backups that stopped working.
#
# Two pieces:
#
#   - `backup-verify`, a nightly CronJob, opens the repository with the
#     passphrase and checks the age of the newest snapshot of every tag it
#     expects. It fails when a tag is missing or older than its limit. That
#     also covers backups this module does not run itself, such as the
#     operator's `operator-config` push from outside the cluster (add it to
#     `freshness_max_age_hours`), and proves nightly that the passphrase
#     still opens the repository.
#   - A PrometheusRule fires when the latest scheduled run of any CronJob in
#     the backup namespace, `backup-verify` included, has not succeeded
#     within two hours. It is independent of the schedules and resolves on
#     the next success.

locals {
  # Snapshot tag => maximum age in hours, for the targets this module backs
  # up. Daily jobs get a day plus slack, the weekly PV tars a week plus
  # slack. `freshness_max_age_hours` overrides or adds tags.
  freshness_builtin = merge(
    length(local.postgres_set) > 0 ? { postgres = 26 } : {},
    length(local.mysql_set) > 0 ? { mysql = 26 } : {},
    length(local.redis_set) > 0 ? { redis = 26 } : {},
    length(local.vault_set) > 0 ? { vault = 26 } : {},
    length(local.pv_groups) > 0 ? { pv = 192 } : {},
  )
  freshness = merge(local.freshness_builtin, var.freshness_max_age_hours)

  alert_rules = var.enabled && var.prometheus_rule_labels != null ? toset(["enabled"]) : toset([])
}

resource "kubernetes_cron_job_v1" "verify" {
  for_each = var.enabled && length(local.freshness) > 0 ? toset(["enabled"]) : toset([])

  metadata {
    name      = "backup-verify"
    namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
  }

  spec {
    schedule                      = var.schedule_verify
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = merge(local.tags, { "app.kubernetes.io/component" = "backup-verify" })
      }
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = merge(local.tags, { "app.kubernetes.io/component" = "backup-verify" })
          }
          spec {
            restart_policy = "Never"

            container {
              name  = "verify"
              image = var.image_restic

              env_from {
                secret_ref {
                  name = kubernetes_secret_v1.backup_creds["enabled"].metadata[0].name
                }
              }
              env {
                name  = "CHECKS"
                value = join(" ", [for tag, hours in local.freshness : "${tag}:${hours}"])
              }

              command = ["sh", "-c"]
              args = [<<-EOT
                set -eu
                now=$(date -u +%s)
                stale=""
                for check in $CHECKS; do
                  tag=$${check%%:*}
                  hours=$${check##*:}
                  # Newest snapshot of the tag across hosts; --no-lock so a
                  # running backup or prune does not block the check.
                  t=$(restic snapshots --no-lock --tag "$tag" --json | grep -o '"time":"[^"]*"' | cut -d'"' -f4 | sort | tail -1)
                  if [ -z "$t" ]; then
                    echo "[verify] $tag: no snapshot at all"
                    stale="$stale $tag"
                    continue
                  fi
                  ts=$(date -u -d "$(echo "$t" | cut -c1-19 | tr T ' ')" +%s)
                  age=$(( (now - ts) / 3600 ))
                  if [ "$age" -gt "$hours" ]; then
                    echo "[verify] $tag: newest snapshot $${age}h old, limit $${hours}h"
                    stale="$stale $tag"
                  else
                    echo "[verify] $tag: ok ($${age}h old, limit $${hours}h)"
                  fi
                done
                if [ -n "$stale" ]; then
                  echo "[verify] STALE:$stale"
                  exit 1
                fi
                echo "[verify] all backups fresh"
              EOT
              ]

              resources {
                requests = { cpu = "50m", memory = "64Mi" }
                limits   = { cpu = "500m", memory = "256Mi" }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.restic_init]
}

resource "kubectl_manifest" "alerts" {
  for_each = local.alert_rules

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "backup-alerts"
      namespace = kubernetes_namespace_v1.backup["enabled"].metadata[0].name
      labels    = merge(local.tags, var.prometheus_rule_labels)
    }
    spec = {
      groups = [{
        name = "backups"
        rules = [{
          alert = "BackupJobFailing"
          # The latest scheduled run is more than two hours old and nothing
          # has succeeded since it was scheduled (or ever).
          expr   = <<-PROMQL
            (
              kube_cronjob_status_last_schedule_time{namespace="${var.namespace}"}
                > kube_cronjob_status_last_successful_time{namespace="${var.namespace}"}
              or
              kube_cronjob_status_last_schedule_time{namespace="${var.namespace}"}
                unless kube_cronjob_status_last_successful_time{namespace="${var.namespace}"}
            )
            and (time() - kube_cronjob_status_last_schedule_time{namespace="${var.namespace}"} > 7200)
          PROMQL
          for    = "10m"
          labels = merge({ severity = "warning" }, var.alert_labels)
          annotations = {
            summary     = "Backup {{ $labels.cronjob }} has not succeeded since its last scheduled run"
            description = "The latest run of CronJob {{ $labels.namespace }}/{{ $labels.cronjob }} was scheduled more than two hours ago and has not completed successfully. Check its Job logs; backup-verify failing means a snapshot tag is missing or too old."
          }
        }]
      }]
    }
  })
}
