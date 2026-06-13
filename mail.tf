# Mail stack — Stalwart 0.16 in the `mail` namespace, SQLite + blob
# storage on hostPath. WebUI (admin + webmail) routes through the
# Cloudflare Tunnel as a kind:external component (config/components/
# mail.yaml) and gets SSO via the Zitadel OIDC directory wired in by
# the module's plan.ndjson. SMTP inbound arrives on host port 25 via
# a tiny socat forwarder (also in `mail`) bound to the WireGuard
# address — Cloudflare Tunnel does not forward TCP/25, the public
# relay forwards there. SMTP outbound is wired to the same relay
# through Stalwart's MtaRoute Relay variant; smarthost values come
# from `local.mail.smarthost.*` (sourced from the domain yaml that
# carries `mail.primary: true`). An empty `smarthost.address` falls
# back to direct MX, which residential ISPs silently swallow.
#
# Tenant-specific values (smarthost target, WG bind IP, public IP for
# SPF, DKIM selector, DMARC policy) live under `mail:` in the primary
# domain's yaml — those files are gitignored. Only the SMTP-AUTH
# password (when used) stays out of yaml: pass via TF_VAR_smarthost_password
# in `.env`. The mail stack is created iff exactly one domain yaml
# sets `mail.primary: true`.

resource "kubernetes_namespace_v1" "mail" {
  for_each = local.mail == null ? toset([]) : toset(["enabled"])

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
# enough room without blowing past a typical home-lab node.
resource "kubernetes_resource_quota_v1" "mail" {
  for_each = local.mail == null ? toset([]) : toset(["enabled"])

  metadata {
    name      = "mail-budget"
    namespace = kubernetes_namespace_v1.mail["enabled"].metadata[0].name
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

# Additional submission-only mail domains. Any domain yaml that sets
# `mail.submission_only: true` lands here as a separate Stalwart
# Domain + DkimSignature pair. Outgoing mail with `From:` matching one
# of these domains gets DKIM-signed with that domain's per-domain key;
# no inbound mailboxes or per-domain user provisioning. Mail stack
# must be enabled (primary domain set) for additional domains to take
# effect — without a primary, the whole Stalwart module is off.
locals {
  _additional_mail_domains = local.mail == null ? {} : {
    for name, cfg in local._domain_configs :
    cfg.slug => {
      name          = cfg.name
      dkim_selector = try(cfg.mail.dkim_selector, "stalwart")
      dmarc_policy  = try(cfg.mail.dmarc_policy, "none")
      dmarc_rua     = try(cfg.mail.dmarc_rua, "")
      zone_id       = try(cfg.cloudflare_zone_id, "")
    }
    if try(cfg.mail.submission_only, false)
  }

  # SMTP-push ingest forwards declared by domain yamls
  # (`mail.ingest_forward`). Machine intake of a mailbox's inbound
  # traffic (campaign bounce/DSN ingest) without minting mailbox
  # credentials — see `modules/stalwart` `ingest_forwards`.
  _mail_ingest_forwards = local.mail == null ? {} : {
    for name, cfg in local._domain_configs :
    cfg.slug => {
      address          = cfg.mail.ingest_forward.address
      synthetic_domain = cfg.mail.ingest_forward.synthetic_domain
      smtp_host        = cfg.mail.ingest_forward.smtp_host
      smtp_port        = try(cfg.mail.ingest_forward.smtp_port, 25)
    }
    if try(cfg.mail.ingest_forward.address, "") != ""
  }
}

module "stalwart" {
  source     = "./modules/stalwart"
  depends_on = [module.addons, module.zitadel, kubernetes_resource_quota_v1.mail]

  context          = module.platform_label.context
  enabled          = local.mail != null
  namespace        = local.mail == null ? "" : kubernetes_namespace_v1.mail["enabled"].metadata[0].name
  volume_base_path = var.host_volume_path

  # Primary domain + matching Cloudflare zone come from the domain
  # yaml that opts in via `mail.primary: true`. Hostname defaults to
  # `mail.<domain>` but can be overridden in yaml.
  primary_domain     = try(local.mail.primary_domain, "")
  hostname           = try(local.mail.hostname, "")
  cloudflare_zone_id = try(local.mail.cloudflare_zone_id, "")

  # Additional submission-only domains. Module emits one Stalwart
  # Domain + DkimSignature per entry into the apply plan; DNS records
  # for each (MX/SPF/DKIM/DMARC) are emitted from this file using the
  # module's `additional_domain_dkim_dns` output.
  additional_domains = {
    for slug, cfg in local._additional_mail_domains :
    slug => {
      name          = cfg.name
      dkim_selector = cfg.dkim_selector
      dmarc_policy  = cfg.dmarc_policy
    }
  }

  # SMTP-push ingest forwards (machine intake of mailbox traffic).
  ingest_forwards = local._mail_ingest_forwards

  # DNS / DKIM knobs from yaml.
  dkim_selector     = try(local.mail.dkim_selector, "stalwart")
  spf_authorized_ip = try(local.mail.spf_authorized_ip, "")
  dmarc_policy      = try(local.mail.dmarc_policy, "quarantine")

  # SMTP inbound forwarder bind IP — typically the WireGuard interface
  # address on the home node so the public relay's outbound tunnel can
  # reach it without exposing :25 on the LAN.
  smtp_relay_listen_ip = try(local.mail.smtp_relay_listen_ip, "")

  # Zitadel wiring — when zitadel is on at platform root, the module
  # creates an OIDC app + role + the bootstrap plan attaches Zitadel
  # as the authentication directory. When off, Stalwart still comes
  # up with internal directory + recovery admin only.
  zitadel_org_id                 = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org["enabled"].ids[0] : ""
  zitadel_issuer_url             = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  zitadel_provider_authenticated = var.zitadel_pat != ""

  # Outbound smart-host. yaml provides target/port/TLS shape. The home
  # cluster's relay accepts mail by source-IP / WG peer-ACL, so SMTP
  # AUTH is unused — `smarthost_username` stays empty and the module's
  # `smarthost_password` defaults to empty too. Operators relaying
  # through an AUTH-required SaaS (Mailgun, SendGrid, etc.) would need
  # to add a `var.smarthost_password` (sensitive, .env-only) and pipe
  # it through here.
  smarthost_address             = try(local.mail.smarthost.address, "")
  smarthost_port                = try(local.mail.smarthost.port, 25)
  smarthost_implicit_tls        = try(local.mail.smarthost.implicit_tls, false)
  smarthost_allow_invalid_certs = try(local.mail.smarthost.allow_invalid_certs, false)
  smarthost_username            = try(local.mail.smarthost.username, "")

  # Pin both Stalwart pods (main + smtp-relay) to the data-bearing
  # node. Main pod owns a hostPath PV that only lives on one node;
  # smtp-relay sidecar binds `smtp_relay_listen_ip` literally and
  # that address only exists on one node either. Empty on a
  # single-node cluster; multi-node operators set this in
  # `mail.node_selector` of their domain yaml.
  node_selector = try(local.mail.node_selector, {})
  tolerations   = try(local.mail.tolerations, [])
}

# Roundcube webmail — fronts the actual mailbox UI at the root of
# mail.<domain>, OIDC-only auth via Zitadel + XOAUTH2 to Stalwart's
# IMAP/SMTP. Stalwart's bundled webui covers admin/account but has
# no inbox view, so a separate webmail component is required for any
# browser-based mail reading.
module "roundcube" {
  source     = "./modules/roundcube"
  depends_on = [module.stalwart]

  context          = module.platform_label.context
  enabled          = local.mail != null && local.platform.services.zitadel.enabled
  namespace        = local.mail == null ? "" : kubernetes_namespace_v1.mail["enabled"].metadata[0].name
  hostname         = try(local.mail.hostname, "")
  volume_base_path = var.host_volume_path

  zitadel_org_id                 = local.platform.services.zitadel.enabled ? data.zitadel_orgs.platform_org["enabled"].ids[0] : ""
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
  for_each = local.platform.services.zitadel.enabled ? toset(["enabled"]) : toset([])

  name        = "ZITADEL"
  name_method = "TEXT_QUERY_METHOD_EQUALS"
}

# ── DNS records for additional submission-only mail domains ──────────────────
#
# Per-entry in `local._additional_mail_domains` emit three TXT records
# onto the additional domain's own Cloudflare zone. No MX here — additional
# domains are outbound-only by default, no inbound mailbox to deliver
# bounces to. Senders that need to bounce a noreply@ message simply
# get a delivery failure their side, which is correct semantics. A
# domain that DOES take inbound mail publishes its MX through the
# generic per-domain `dns:` record list instead (same as the primary),
# with the relay + Stalwart side provisioned by the operator.
#
#   - SPF → `v=spf1 ip4:<relay-public-ip> -all` — same authorised sender IP
#           as primary. Without SPF every receiver flags forged-sender risk.
#   - DKIM → per-domain `<selector>._domainkey` TXT carrying the public key
#           Stalwart signs with for this domain.
#   - DMARC → `_dmarc` TXT with policy from yaml. Default `none`. `rua`
#           is emitted only when the yaml sets `mail.dmarc_rua` (an
#           address that actually receives mail — see the `dns:` MX
#           note above); otherwise the field is omitted rather than
#           pointing at a non-existent mailbox.

resource "cloudflare_dns_record" "additional_mail_spf" {
  for_each = {
    for slug, cfg in local._additional_mail_domains : slug => cfg
    if try(local.mail.spf_authorized_ip, "") != ""
  }

  zone_id = each.value.zone_id
  name    = each.value.name
  type    = "TXT"
  content = "\"v=spf1 ip4:${try(local.mail.spf_authorized_ip, "")} -all\""
  ttl     = 300
  comment = "additional mail domain — SPF authorises only the relay public IP"
}

resource "cloudflare_dns_record" "additional_mail_dkim" {
  for_each = local._additional_mail_domains

  zone_id = each.value.zone_id
  name    = "${module.stalwart.additional_domain_dkim_dns[each.key].name}.${each.value.name}"
  type    = "TXT"
  content = "\"${module.stalwart.additional_domain_dkim_dns[each.key].value}\""
  ttl     = 300
  comment = "additional mail domain — DKIM TXT (per-domain key, signed by Stalwart on outbound)"
}

resource "cloudflare_dns_record" "additional_mail_dmarc" {
  for_each = local._additional_mail_domains

  zone_id = each.value.zone_id
  name    = "_dmarc.${each.value.name}"
  type    = "TXT"
  content = "\"v=DMARC1; p=${each.value.dmarc_policy}${each.value.dmarc_rua != "" ? "; rua=mailto:${each.value.dmarc_rua}" : ""}\""
  ttl     = 300
  comment = "additional mail domain — DMARC policy (rua only when the yaml provides a receiving address)"
}
