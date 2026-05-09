output "enabled" {
  value = var.enabled
}

output "namespace" {
  value = var.namespace
}

output "hostname" {
  value = var.hostname
}

output "service_name" {
  value = var.enabled ? kubernetes_service_v1.vault["enabled"].metadata[0].name : null
}

output "port" {
  value = 8200
}

output "url" {
  description = "Public Vault URL — `terraform output -raw vault_url`."
  value       = var.enabled && var.hostname != "" ? "https://${var.hostname}" : null
}

output "root_token" {
  description = "Root token emitted by `vault operator init`. Use as break-glass when OIDC is broken or before Phase 1 lands. Read with `terraform output -raw vault_root_token`. Empty until the init Job has run + plan picks up the populated Secret on the second apply (k8s data sources are read at plan time)."
  value       = var.enabled ? try(data.kubernetes_secret_v1.vault_bootstrap["enabled"].data["root-token"], "") : null
  sensitive   = true
}

output "unseal_key" {
  description = "Single unseal key (secret_shares=1, secret_threshold=1 — single-operator home cluster, no shamir benefit). Used by the StatefulSet's postStart hook to auto-unseal on every pod start. Read with `terraform output -raw vault_unseal_key` if you need to unseal manually for some reason."
  value       = var.enabled ? try(data.kubernetes_secret_v1.vault_bootstrap["enabled"].data["unseal-key"], "") : null
  sensitive   = true
}
