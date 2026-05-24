# Per-zone Cloudflare settings managed at the engine level.
#
# Zones themselves are NOT created by Terraform here — they pre-exist
# in the operator's Cloudflare account and are referenced by
# `cloudflare_zone_id` in each `config/domains/<name>.yaml`. The engine
# only manages zone-level SETTINGS that are operator-policy decisions:
# DNSSEC today, potentially TLS minimum / WAF posture / bot management
# later.
#
# Opt-in per domain via `dnssec_enabled: true` on the domain yaml.
# Default off — the engine does not flip DNSSEC on zones that haven't
# explicitly asked. Disabling (removing the flag or setting false)
# tears the resource down, which IS destructive — Cloudflare disables
# the DNSSEC signing at the zone, parent-zone DS records would need
# manual removal at the registrar.

locals {
  # Domains that opted into DNSSEC. Keyed by domain name for stable
  # for_each (zone_ids are stable but less greppable in plan output).
  _dnssec_zones = {
    for name, cfg in local._domain_configs :
    name => cfg.cloudflare_zone_id
    if try(cfg.dnssec_enabled, false) && try(cfg.cloudflare_zone_id, "") != ""
  }
}

# DNSSEC enable per opted-in zone. The provider resource is "make
# DNSSEC active on this zone"; computed attributes (`digest`,
# `key_tag`, `algorithm`, etc.) are exposed via the output below so
# the operator can paste DS records into the registrar when the
# registrar isn't Cloudflare itself.
resource "cloudflare_zone_dnssec" "this" {
  for_each = local._dnssec_zones

  zone_id = each.value
  status  = "active"
}

# DS records the operator submits to the parent registrar to chain
# the DNSSEC trust. When the zone's registrar IS Cloudflare,
# Cloudflare handles the parent-DS injection automatically and this
# output is reference-only. When the registrar is external (Namecheap,
# Porkbun, etc.), the operator copy-pastes from here into the
# registrar's DNSSEC panel.
output "cloudflare_dnssec_ds_records" {
  description = "DS records per DNSSEC-enabled domain. Submit to the parent registrar (only needed when the registrar is NOT Cloudflare itself; Cloudflare-registered domains auto-chain). Keyed by domain name; each value carries the DS record fields the registrar UI expects (`key_tag`, `algorithm`, `digest_type`, `digest`)."
  value = {
    for name, _ in local._dnssec_zones :
    name => {
      key_tag     = cloudflare_zone_dnssec.this[name].key_tag
      algorithm   = cloudflare_zone_dnssec.this[name].algorithm
      digest_type = cloudflare_zone_dnssec.this[name].digest_type
      digest      = cloudflare_zone_dnssec.this[name].digest
      ds          = cloudflare_zone_dnssec.this[name].ds
    }
  }
}
