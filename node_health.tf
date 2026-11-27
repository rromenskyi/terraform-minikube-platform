# Hung-kernel detection and taint — root wiring.
#
# node-problem-detector turns "task ... blocked for more than N seconds"
# into the node condition KernelDeadlock; node-readiness-controller keeps a
# NoSchedule taint on the node while it holds. Operator drives the toggle
# and dry-run via `services.node_health` in `config/platform.yaml`.

module "node_health" {
  source     = "./modules/node-health"
  depends_on = [module.addons]

  enabled = local.platform.services.node_health.enabled
  dry_run = local.platform.services.node_health.dry_run
}
