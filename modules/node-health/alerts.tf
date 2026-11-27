# ── Alerts ─────────────────────────────────────────────────────────────────

resource "kubectl_manifest" "rules" {
  for_each = local.set

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "node-health"
      namespace = var.namespace
      labels    = var.prometheus_selector_labels
    }
    spec = {
      groups = [{
        name = "node-health"
        rules = [
          {
            # Fires until the node reboots (or node-problem-detector on it is
            # restarted). Do not add it to kured's blocking alerts: the
            # reboot is the fix.
            alert  = "NodeKernelDeadlock"
            expr   = "kube_node_status_condition{condition=\"KernelDeadlock\",status=\"true\"} == 1"
            labels = { severity = "critical" }
            annotations = {
              summary     = "{{ $labels.node }}: kernel tasks are hung; new pods are kept off the node"
              description = "node-problem-detector saw \"task ... blocked for more than N seconds\" in the kernel log (journalctl -k). Processes in state D cannot be killed; a reboot is usually the only fix.${var.dry_run ? " The taint is in dry-run mode: nothing was tainted." : ""} If the stall was transient, delete the node-problem-detector pod on that node more than five minutes after the last hung-task line to clear the condition."
            }
          },
          {
            alert  = "NodeKernelDeadlockSeveralNodes"
            expr   = "count(kube_node_status_condition{condition=\"KernelDeadlock\",status=\"true\"} == 1) > 1"
            labels = { severity = "critical" }
            annotations = {
              summary = "{{ $value }} nodes report hung kernel tasks at once: check shared storage before rebooting them"
            }
          },
          {
            alert  = "NodeProblemDetectorUnavailable"
            expr   = "kube_daemonset_status_number_unavailable{namespace=\"${var.namespace}\",daemonset=\"node-problem-detector\"} > 0"
            for    = "15m"
            labels = { severity = "warning" }
            annotations = {
              summary = "node-problem-detector is not running on {{ $value }} node(s): hung kernels there go unnoticed"
            }
          },
        ]
      }]
    }
  })
}
