# SMART data of the nodes' physical drives — root wiring.
#
# The module owns the smartctl_exporter release and the "Disk health"
# Grafana dashboard (wear, days left, writes, write latency, top writers).
# Operator drives toggle + node placement via `services.disk_health` in
# `config/platform.yaml`; `affinity` keeps it off VM nodes, whose virtual
# disks have no SMART data.

module "disk_health" {
  source     = "./modules/disk-health"
  depends_on = [module.addons]

  context = module.platform_label.context

  enabled                   = local.platform.services.disk_health.enabled
  affinity                  = local.platform.services.disk_health.affinity
  grafana_dashboard_enabled = true
}
