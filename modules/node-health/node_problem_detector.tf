# ── node-problem-detector ──────────────────────────────────────────────────

resource "helm_release" "node_problem_detector" {
  for_each = local.set

  name        = "node-problem-detector"
  repository  = "oci://ghcr.io/deliveryhero/helm-charts"
  chart       = "node-problem-detector"
  version     = var.npd_chart_version
  namespace   = var.namespace
  max_history = 3

  values = [yamlencode({
    fullnameOverride = "node-problem-detector"
    image = {
      repository = var.npd_image_repository
      tag        = var.npd_image_tag
    }
    settings = {
      # Our kernel monitor replaces the stock one; the stock Docker and
      # read-only monitors are left out (containerd, no Docker).
      custom_monitor_definitions = {
        "kernel-monitor.json" = file("${path.module}/kernel-monitor.json")
      }
      log_monitors = ["/custom-config/kernel-monitor.json"]
    }
    # Run on every node, whatever its taints, including the one this module
    # sets: the condition must clear on the node it was raised on.
    tolerations = [{ operator = "Exists" }]
    resources   = var.npd_resources
  })]
}
