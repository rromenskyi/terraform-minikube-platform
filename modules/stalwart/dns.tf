# ── Mail-auth DNS records (SPF / DKIM / DMARC) ───────────────────────────────
#
# Emitted directly as `cloudflare_record` resources rather than going
# through `config/domains/<x>.yaml` because the values are TF-derived
# (DKIM body comes from `tls_private_key.dkim`, SPF/DMARC from module
# vars). Hand-pasting the rendered DKIM body into yaml every key
# rotation would be busy-work; this keeps the source-of-truth single.
resource "cloudflare_dns_record" "spf" {
  for_each = local.spf_record_set

  zone_id = var.cloudflare_zone_id
  # v5 requires FQDN — `@` is no longer accepted.
  name    = var.primary_domain
  type    = "TXT"
  content = local.spf_dns_value
  proxied = false
  ttl     = 300
  comment = "SPF — managed by modules/stalwart (terraform-minikube-platform)"
}

resource "cloudflare_dns_record" "dkim" {
  for_each = local.dns_records_set

  zone_id = var.cloudflare_zone_id
  name    = "${local.dkim_dns_name}.${var.primary_domain}"
  type    = "TXT"
  content = local.dkim_dns_value
  proxied = false
  ttl     = 300
  comment = "DKIM — managed by modules/stalwart (terraform-minikube-platform)"
}

resource "cloudflare_dns_record" "dmarc" {
  for_each = local.dmarc_record_set

  zone_id = var.cloudflare_zone_id
  name    = "_dmarc.${var.primary_domain}"
  type    = "TXT"
  content = local.dmarc_dns_value
  proxied = false
  ttl     = 300
  comment = "DMARC — managed by modules/stalwart (terraform-minikube-platform)"
}

# DKIM RSA key — rendered into the bootstrap plan's DkimSignature.
# Stable: tls_private_key keeps the same value across applies, so the
# public key in DNS doesn't churn. Rotation = taint this resource +
# bump the selector var.
resource "tls_private_key" "dkim" {
  for_each = local.instances

  algorithm = "RSA"
  rsa_bits  = 2048
}

# Per-additional-domain DKIM keypair. One RSA-2048 pair per entry in
# `var.additional_domains`; engine pairs it with a Stalwart
# DkimSignature object referencing that domain. Stable in TF state —
# never rotated by accident.
resource "tls_private_key" "dkim_additional" {
  for_each = var.enabled ? var.additional_domains : {}

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "random_password" "recovery_admin" {
  for_each = local.instances

  length  = 32
  special = false
}

# Random URL prefix in front of /admin and /account so the operator-only
# Stalwart UI sits at `mail.<domain>/<random>/admin` etc. The webmail
# (Roundcube) lives at the root and is the only path normal users
# touch; admin lives behind URL-obscurity so unauthenticated drive-by
# scans don't even hit the OIDC-protected admin login screen. Stable
# across applies (no triggers), changes only when the resource is
# explicitly tainted.
resource "random_password" "admin_path" {
  for_each = local.instances

  length  = 16
  special = false
  upper   = false
}

resource "kubernetes_secret_v1" "recovery_admin" {
  for_each = local.instances

  metadata {
    name      = "stalwart-recovery-admin"
    namespace = var.namespace
    labels    = local.tags
  }

  data = {
    username = "admin"
    password = random_password.recovery_admin["enabled"].result
    # Ready-to-paste env var format (`username:password`) — main
    # container references this key directly.
    recovery_admin_env = "admin:${random_password.recovery_admin["enabled"].result}"
  }
}
