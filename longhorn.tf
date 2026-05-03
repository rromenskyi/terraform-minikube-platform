# Longhorn — distributed block storage for the platform.
#
# Phase A scope: install + StorageClass + native B2 backup
# target. Migration of existing hostPath PVs to Longhorn (web,
# wordpress, mail) lives in a follow-up PR — `modules/component`
# needs `storage_class` + `git_sync` support before the static
# `web` component can move off the original-node-only hostPath.
#
# Backup target re-uses the existing B2 bucket the restic
# pipeline writes to, with a dedicated `longhorn-volumes/`
# prefix. Longhorn's native backup format isn't restic-compatible,
# so the two pipelines run side-by-side rather than one feeding
# the other. RecurringJob CRD applies a daily snapshot policy to
# every volume created on the `longhorn` StorageClass.

module "longhorn" {
  source     = "./modules/longhorn"
  depends_on = [module.addons]

  enabled               = local.platform.services.longhorn.enabled
  default_replica_count = local.platform.services.longhorn.replica_count
  tolerations           = local.platform.services.longhorn.tolerations

  # B2 backup target. Re-uses the same bucket and credentials
  # the restic pipeline writes to (under a different prefix —
  # `longhorn-volumes/` — so the two pipelines stay isolated).
  # Empty when `services.backup.enabled = false`; Longhorn still
  # installs but the backup target is unconfigured.
  backup_b2_bucket            = var.backup_b2_bucket
  backup_b2_endpoint          = var.backup_b2_endpoint
  backup_b2_region            = local.platform.services.longhorn.backup_b2_region
  backup_b2_access_key_id     = var.backup_b2_access_key_id
  backup_b2_secret_access_key = var.backup_b2_secret_access_key
}

output "longhorn_storage_class" {
  description = "StorageClass name to set on PVCs that should land on Longhorn-managed volumes. Null when Longhorn is disabled."
  value       = module.longhorn.storage_class
}

output "longhorn_backup_target" {
  description = "Longhorn S3 backup target URL, or null when backup is unconfigured."
  value       = module.longhorn.backup_target
}
