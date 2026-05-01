# Mail stack — Stalwart 0.16 in the `mail` namespace, SQLite + blob
# storage on hostPath. WebUI (admin + webmail) routes through the
# Cloudflare Tunnel as a kind:external component (config/components/
# mail.yaml) and gets SSO via the Zitadel OIDC directory wired in by
# the module's plan.ndjson. SMTP inbound arrives on host port 25 via
# a tiny socat forwarder (also in `mail`) bound to the WireGuard
# address — Cloudflare Tunnel does not forward TCP/25, the public
# relay forwards there. SMTP outbound is wired to the same relay
# through Stalwart's MtaRoute Relay variant; smarthost vars
# (var.smarthost_*) plumb in at the module call below. An empty
# smarthost_address falls back to direct MX, which residential ISPs
# silently swallow.

resource "kubernetes_namespace_v1" "mail" {
  metadata {
    name = "mail"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "platform"
    }
  }
}

# Mail namespace resource budget. Sized to fit Stalwart + Roundcube +
# the SMTP relay forwarder + applier sidecar with a small headroom
# for future webmail accounts.
#
# Stalwart's main container is 500m/768Mi limits, applier 200m/128Mi,
# Roundcube 200m/256Mi, smtp-relay 100m/32Mi — a hair under 1.1Gi
# memory limits with all four pods running, plus the operator's
# expected mailbox count is one digit. 2Gi memory + 2 CPU leaves
# enough room without blowing past the 32Gi / 12-CPU node.
resource "kubernetes_resource_quota_v1" "mail" {
  metadata {
    name      = "mail-budget"
    namespace = kubernetes_namespace_v1.mail.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    hard = {
      "requests.cpu"    = "1"
      "requests.memory" = "1Gi"
      "limits.cpu"      = "2"
      "limits.memory"   = "2Gi"
      "pods"            = "6"
    }
  }
}

module "stalwart" {
  source     = "./modules/stalwart"
  depends_on = [module.addons, module.zitadel, kubernetes_resource_quota_v1.mail]

  enabled          = true
  namespace        = kubernetes_namespace_v1.mail.metadata[0].name
  volume_base_path = var.host_volume_path

  # Primary domain + matching Cloudflare zone come from the same
  # entry in `_domain_configs`. `primary_mail_domain` is the variable
  # operators flip when the home of mail moves to a different tenant
  # — everything else (DKIM/SPF/DMARC TXT records, the mail UI's
  # `defaultDomainId`, OIDC auto-provisioning) follows from it.
  primary_domain     = var.primary_mail_domain
  hostname           = "mail.${var.primary_mail_domain}"
  cloudflare_zone_id = try(local._domain_configs[var.primary_mail_domain].cloudflare_zone_id, "")

  # Zitadel wiring — when zitadel is on at platform root, the module
  # creates an OIDC app + role + the bootstrap plan attaches Zitadel
  # as the authentication directory. When off, Stalwart still comes
  # up with internal directory + recovery admin only.
  zitadel_org_id                 = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org[0].ids[0] : ""
  zitadel_issuer_url             = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  zitadel_provider_authenticated = var.zitadel_pat != ""

  # Outbound smart-host — set TF_VAR_smarthost_address (and the
  # adjacent _port / _username / _password if the relay needs auth)
  # in `.env` to push every non-local message through the public
  # Postfix relay VPS. Empty leaves Stalwart on direct-MX which the
  # network silently swallows.
  smarthost_address             = var.smarthost_address
  smarthost_port                = var.smarthost_port
  smarthost_implicit_tls        = var.smarthost_implicit_tls
  smarthost_allow_invalid_certs = var.smarthost_allow_invalid_certs
  smarthost_username            = var.smarthost_username
  smarthost_password            = var.smarthost_password
}

# Roundcube webmail — fronts the actual mailbox UI at the root of
# mail.<domain>, OIDC-only auth via Zitadel + XOAUTH2 to Stalwart's
# IMAP/SMTP. Stalwart's bundled webui covers admin/account but has
# no inbox view, so a separate webmail component is required for any
# browser-based mail reading.
module "roundcube" {
  source     = "./modules/roundcube"
  depends_on = [module.stalwart]

  enabled          = local.platform.services.zitadel.enabled
  namespace        = kubernetes_namespace_v1.mail.metadata[0].name
  hostname         = "mail.${var.primary_mail_domain}"
  volume_base_path = var.host_volume_path

  zitadel_org_id                 = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org[0].ids[0] : ""
  zitadel_issuer_url             = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  zitadel_provider_authenticated = var.zitadel_pat != ""
  zitadel_project_id             = local.platform.services.zitadel.enabled ? module.stalwart.zitadel_project_id : ""
}

# Zitadel org lookup — Stalwart's OIDC app + role need an org_id and
# the existing per-domain `forward-auth` project lives under it. One
# extra round-trip per plan when Zitadel is disabled is the price of
# keeping the data source unconditionally referenced; gating it on
# `enabled` would pull org_id resolution into the apply phase and
# every dependent resource would re-plan as "must replace".
data "zitadel_orgs" "platform_org" {
  count = local.platform.services.zitadel.enabled ? 1 : 0

  name        = "ZITADEL"
  name_method = "TEXT_QUERY_METHOD_EQUALS"
}
