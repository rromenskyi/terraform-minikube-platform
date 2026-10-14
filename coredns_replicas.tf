# CoreDNS replica count.
#
# k3s deploys CoreDNS from its own addon manifest with a single replica, so
# the node running it is a single point of failure for every in-cluster name
# lookup: a highly available database behind `postgres.platform.svc` is no
# help to clients that can no longer resolve the name.
#
# The manifest sets no `replicas`, so the count is pinned with a
# HorizontalPodAutoscaler (min = max) rather than by editing the Deployment
# k3s owns; k3s's re-applies leave it alone. Removing the HPA returns CoreDNS
# to the k3s default. The manifest already spreads the pods one per node
# (topologySpreadConstraints on the hostname); nodes with a taint CoreDNS
# does not tolerate get none.
#
# Operator config (`config/platform.yaml`):
#
#   services:
#     coredns:
#       replicas: 3   # 0 = leave the k3s default (1)

resource "kubernetes_horizontal_pod_autoscaler_v2" "coredns" {
  for_each = local.platform.services.coredns.replicas > 0 ? toset(["enabled"]) : toset([])

  metadata {
    name      = "coredns"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "coredns"
    }
    min_replicas = local.platform.services.coredns.replicas
    max_replicas = local.platform.services.coredns.replicas
  }
}
