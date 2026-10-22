# ── Volume claims for chart-managed workloads ─────────────────────────────────
#
# `envs.<env>.volume_claims:` — claims a chart mounts by name (e.g. a shared
# ReadWriteMany volume) while the engine owns the storage side: class and
# size live in the platform config, not in the chart.
resource "kubernetes_persistent_volume_claim_v1" "chart" {
  for_each = var.volume_claims

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  spec {
    access_modes       = each.value.access_modes
    storage_class_name = each.value.storage_class

    resources {
      requests = {
        storage = each.value.size
      }
    }
  }

  # Classes with WaitForFirstConsumer bind when the chart's pod is scheduled.
  wait_until_bound = false
}
