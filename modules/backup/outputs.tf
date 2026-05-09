output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Backups namespace, or null when disabled."
}

output "passphrase" {
  value       = local.passphrase
  sensitive   = true
  description = "restic repository passphrase. Pull with `terraform output -raw backup_passphrase` (root output) and stash in a password manager — losing it bricks every backup."
}

output "repository_url" {
  value       = var.enabled ? local.repository_url : null
  description = "restic repository URL (`s3:<endpoint>/<bucket>`). Used by the wrapper-side `./tf backup-config` command and by every restore-script."
}
