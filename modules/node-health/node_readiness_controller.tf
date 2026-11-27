# ── node-readiness-controller ──────────────────────────────────────────────

resource "helm_release" "node_readiness_controller" {
  for_each = local.set

  name        = "node-readiness-controller"
  repository  = "oci://registry.k8s.io/node-readiness-controller/charts"
  chart       = "node-readiness-controller"
  version     = var.nrc_chart_version
  namespace   = var.namespace
  max_history = 3

  values = [yamlencode({
    fullnameOverride = "node-readiness-controller"
  })]
}

resource "kubectl_manifest" "kernel_deadlock_rule" {
  for_each   = local.set
  depends_on = [helm_release.node_readiness_controller]

  yaml_body = yamlencode({
    apiVersion = "readiness.node.x-k8s.io/v1alpha1"
    kind       = "NodeReadinessRule"
    metadata   = { name = "kernel-deadlock" }
    spec = {
      # Healthy = KernelDeadlock False or not reported (a node without
      # node-problem-detector yet is not tainted).
      conditions      = [{ type = "KernelDeadlock", requiredStatus = "False", defaultStatus = "False" }]
      enforcementMode = "continuous"
      taint           = { key = local.taint_key, effect = "NoSchedule", value = "hung-tasks" }
      nodeSelector    = { matchLabels = var.node_selector }
      # With dryRun the controller only reports what it would do, in the
      # rule's status.dryRunResults.
      dryRun = var.dry_run
    }
  })
}
