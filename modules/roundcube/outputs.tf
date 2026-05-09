# ── Outputs ───────────────────────────────────────────────────────────────────
output "service_name" {
  value = var.enabled ? kubernetes_service_v1.roundcube["enabled"].metadata[0].name : null
}

output "namespace" {
  value = var.namespace
}

output "zitadel_application_oidc_id" {
  value = local.oidc_enabled ? zitadel_application_oidc.roundcube["enabled"].id : null
}
