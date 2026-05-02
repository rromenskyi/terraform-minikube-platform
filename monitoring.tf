# Monitoring namespace request budget.
#
# The `monitoring` namespace itself is owned upstream by
# `module.addons` (terraform-k8s-addons → kube-prometheus-stack
# chart). The chart sets `requests` on a few containers (Prometheus,
# Alertmanager) but no `limits` on anything. Under node pressure the
# OOMKiller picks the largest unbounded process first — usually
# Prometheus' head block — which is the failure mode this stack is
# closest to.
#
# This file does NOT add per-container limits — that must come from
# Helm values on the kube-prometheus-stack release (separate PR in
# terraform-k8s-addons + a tag bump). Setting them here via
# `LimitRange.default` is tempting but breaks the math: ~12
# chart-managed containers × any sane default exceeds a per-namespace
# memory quota the operator can stomach. Per-pod values are the
# correct lever.
#
# What this file DOES do is a request-side namespace budget:
#   * caps total `requests.cpu` / `requests.memory` summed across all
#     pods in the namespace — the scheduler can't oversubscribe the
#     node by stacking unbounded chart upgrades.
#   * caps pod count so a runaway Operator can't fork off thousands
#     of probes and exhaust IPs / kubelet budget.
#
# Sizing comes from `config/limits/monitoring.yaml` (committed). When
# Prometheus retention or scrape volume grows past the cap, bump
# there — the apply re-renders the quota in seconds, no pod
# disruption.
#
# Critical: only `requests.*` and `pods` go into quota.hard —
# Kubernetes makes any field listed there mandatory on every new pod
# in the namespace. Adding `limits.cpu` / `limits.memory` would force
# every chart-managed container to declare its own limits or get
# rejected at admission. The chart doesn't, so we don't either.
resource "kubernetes_resource_quota_v1" "monitoring" {
  depends_on = [module.addons]

  metadata {
    name      = "monitoring-budget"
    namespace = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    hard = {
      "requests.cpu"    = try(local.namespace_limits.monitoring.cpu, local.default_limits.cpu)
      "requests.memory" = try(local.namespace_limits.monitoring.memory, local.default_limits.memory)
      "pods"            = tostring(try(local.namespace_limits.monitoring.pods, local.default_limits.pods, 30))
    }
  }
}
