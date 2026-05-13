# Continuous CVE scanning of platform-system images — root wiring.
#
# Module owns the trivy-operator helm release, the snapshot CronJob,
# the trivy DB cache PV/PVC, and the Vault-backed PAT consumption.
# Operator drives toggle + tuning via `services.security_scan` in
# `config/platform.yaml`. See `modules/security-scan/main.tf` header
# for the two-layer architecture rationale.

module "security_scan" {
  source = "./modules/security-scan"

  context = module.platform_label.context

  enabled                      = local.platform.services.security_scan.enabled
  trivy_operator_chart_version = local.platform.services.security_scan.trivy_operator_chart_version
  cache_node_hostname          = local.platform.services.security_scan.cache_node_hostname
  host_volume_path             = var.host_volume_path
  trivy_cache_size             = local.platform.services.security_scan.trivy_cache_size
  service_monitor_enabled      = local.platform.services.security_scan.service_monitor_enabled
  snapshot_schedule            = local.platform.services.security_scan.snapshot_schedule
  github_repo                  = local.platform.services.security_scan.github_repo
  branch_prefix                = local.platform.services.security_scan.branch_prefix
  telegram_notify_enabled      = local.platform.services.security_scan.telegram_notify_enabled
  telegram_vault_path          = local.platform.services.security_scan.telegram_vault_path
}
