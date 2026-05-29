output "namespace" {
  value = var.namespace
}

output "service_http" {
  description = "ClusterIP Service serving Stalwart's HTTP (admin + webmail + JMAP). Cloudflare Tunnel ingress routes mail.<domain> here via a kind:external component in the domain yaml."
  value = var.enabled ? {
    name      = kubernetes_service_v1.stalwart_http["enabled"].metadata[0].name
    namespace = kubernetes_service_v1.stalwart_http["enabled"].metadata[0].namespace
    port      = 8080
  } : null
}

output "recovery_admin_secret" {
  description = "Name of the Secret holding the pinned recovery / fallback admin credentials. Read username + password with `kubectl get secret <name> -n mail -o jsonpath='{.data.password}' | base64 -d`."
  value       = var.enabled ? kubernetes_secret_v1.recovery_admin["enabled"].metadata[0].name : null
}

output "recovery_admin_username" {
  description = "Username for the pinned recovery / fallback admin (always `admin`). Pairs with `recovery_admin_password` for direct WebUI login that bypasses the OIDC directory."
  value       = var.enabled ? "admin" : null
}

output "recovery_admin_password" {
  description = "Plaintext password for the pinned recovery / fallback admin. Sensitive — surface with `terraform output -raw stalwart_recovery_admin_password` (root-level alias defined in outputs.tf). Bypasses the directory entirely; use whenever OIDC sign-in is broken or unavailable."
  value       = var.enabled ? random_password.recovery_admin["enabled"].result : null
  sensitive   = true
}

output "zitadel_application_oidc_id" {
  description = "ID of the Zitadel OIDC application provisioned for Stalwart's WebUI; null when Zitadel integration is disabled. Used by the operator to grant `mail-admin` to specific users."
  value       = local.oidc_enabled ? zitadel_application_oidc.stalwart["enabled"].id : null
}

output "zitadel_project_id" {
  description = "ID of the Zitadel project the Stalwart OIDC app + roles land in. Re-used by sibling modules (roundcube webmail) so additional OIDC clients pile under the same project rather than spawning new ones."
  value       = local.oidc_enabled ? zitadel_project.stalwart["enabled"].id : null
}

output "admin_url" {
  description = "Operator-facing Stalwart admin URL — `https://mail.<domain>/<random>/admin`. The random prefix is generated once per cluster and stays stable across applies; it surfaces ONLY here and in the platform cheatsheet so admin doesn't surface on the host root (which now serves Roundcube webmail). Do not paste publicly."
  value       = local.webui_admin_url
  sensitive   = true
}

output "account_url" {
  description = "Stalwart self-service account URL — same random prefix as admin_url, lands users on Stalwart's `/account` (sessions, password — mostly empty for OIDC users since password lives in Zitadel)."
  value       = local.webui_account_url
  sensitive   = true
}

output "zitadel_admin_role" {
  description = "Name of the Zitadel project role that grants Stalwart admin via the OIDC `groups` claim; null when Zitadel integration is disabled."
  value       = local.oidc_enabled ? zitadel_project_role.admin["enabled"].role_key : null
}

output "dkim_dns_name" {
  description = "Name component of the DKIM TXT record (relative to the primary domain). Concatenate with the domain to get the FQDN — e.g. `<dkim_selector>._domainkey.<primary_domain>`."
  value       = var.enabled ? local.dkim_dns_name : null
}

output "dkim_dns_value" {
  description = "Value of the DKIM TXT record. Drop verbatim into `config/domains/<primary>.yaml`'s `dns:` block as `{ name: <dkim_selector>._domainkey, type: TXT, content: \"<this>\" }`."
  value       = var.enabled ? local.dkim_dns_value : null
}

output "spf_dns_value" {
  description = "Recommended SPF TXT for the primary domain — authorises only the relay's public IP and rejects everything else (`-all`). Empty when `var.spf_authorized_ip` is unset."
  value       = var.enabled ? local.spf_dns_value : null
}

output "dmarc_dns_name" {
  description = "Name component of the DMARC TXT record."
  value       = "_dmarc"
}

output "dmarc_dns_value" {
  description = "Recommended DMARC policy — quarantine (move-to-spam) on auth failure, aggregate reports to postmaster of the primary domain. Tighten to `p=reject` after a few weeks of clean reports."
  value       = var.enabled ? "v=DMARC1; p=quarantine; rua=mailto:postmaster@${var.primary_domain}" : null
}

output "additional_domain_dkim_dns" {
  description = "Per-additional-domain DKIM TXT record value, keyed by the slug used in `var.additional_domains`. Each entry has `{ name = <selector>._domainkey, value = \"v=DKIM1; k=rsa; p=...\" }` — root mail.tf emits a `cloudflare_dns_record` per entry directly onto the matching CF zone. Empty map when `var.additional_domains` is empty."
  value = {
    for slug, cfg in var.additional_domains :
    slug => {
      name  = "${cfg.dkim_selector}._domainkey"
      value = local.additional_dkim_dns_value[slug]
    }
  }
}

output "zitadel_user_role" {
  description = "Name of the Zitadel project role required for ordinary mailbox access. Operator grants this (or `zitadel_admin_role`) to every Zitadel user who should reach the webmail; users without a project-role are rejected at /authorize."
  value       = local.oidc_enabled ? zitadel_project_role.user["enabled"].role_key : null
}
