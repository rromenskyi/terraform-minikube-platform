# ── Locals: flatten all project hostnames ─────────────────────────────────────

locals {
  # Every routed hostname, collected from every project module.
  # Single source of truth for both the Cloudflare tunnel ingress rules and
  # the per-host CNAME DNS records below. Infra routes (Grafana, Traefik
  # dashboard, …) are emitted by the same tenant machinery via
  # `kind: external` components in `config/components/` — no separate
  # infra code path here.
  all_hostnames = merge([
    for _, proj in module.project : proj.hostnames
  ]...)
}

# ── Cloudflare Zero Trust Tunnel ─────────────────────────────────────────────

# Terraform-owned tunnel secret. Cloudflare uses this shared key to sign the
# JWT (`tunnel_token`) that cloudflared pods present to the control plane —
# cloudflared itself never sees this secret, only the derived token. Generated
# here instead of taking a `.env` input because `./tf bootstrap-*` is a
# destroy-and-recreate flow by design, so there is no state-loss recovery
# story that needs a human-memorised secret. `random_password` (not
# `random_id`) so the value is already a string that `base64encode` accepts
# without hex→bytes rewiring.
resource "random_password" "cloudflare_tunnel_secret" {
  length  = 48
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id    = var.cloudflare_account_id
  name          = "platform"
  config_src    = "cloudflare"
  tunnel_secret = base64encode(random_password.cloudflare_tunnel_secret.result)
}

# Pre-destroy force-delete for the tunnel above.
#
# Cloudflare's API refuses to delete a tunnel while it sees "active
# connections" on its side — which lags the actual cloudflared pods by
# 30-90s after they stop. The v4 provider retries internally with no
# user-configurable ceiling and blocks `terraform destroy` for 3-5
# minutes on every teardown (the `timeouts` block is not on the
# resource's schema).
#
# Short-circuit by hitting the Cloudflare API directly with
# `?force=true` on a 30s curl timeout. The null_resource runs its
# destroy provisioner *before* the managed tunnel resource runs its own
# destroy (dependency order: tunnel → null_resource), so when the
# provider gets to the tunnel it's already gone and returns quickly.
#
# `on_failure = continue` so a missing tunnel (already purged by the
# wrapper's `cloudflare-purge` subcommand) or a transient network hiccup
# does not strand the destroy.
resource "null_resource" "cloudflare_tunnel_force_delete" {
  depends_on = [cloudflare_zero_trust_tunnel_cloudflared.main]

  triggers = {
    tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
    account_id = var.cloudflare_account_id
    api_token  = var.cloudflare_api_token
  }

  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["bash", "-c"]
    environment = {
      ACCOUNT_ID = self.triggers.account_id
      TUNNEL_ID  = self.triggers.tunnel_id
      API_TOKEN  = self.triggers.api_token
    }
    command = <<-EOT
      set -euo pipefail
      curl -fsS --max-time 30 \
        -X DELETE \
        -H "Authorization: Bearer $API_TOKEN" \
        "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID?force=true" \
        > /dev/null
    EOT
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  # v5 schema: `ingress_rule` is a list-of-objects attribute, not a
  # block. End-to-end TLS to Traefik is enforced via `origin_request.
  # origin_server_name` — without it, cloudflared would SNI as the
  # upstream service URL host, Traefik would fall back to its
  # self-signed default cert, and cloudflared would reject it. Setting
  # SNI to the public hostname lets Traefik serve the correct Let's
  # Encrypt cert, which cloudflared validates cleanly.
  #
  # `http2_origin` is opt-in via the component yaml — flips cloudflared
  # from HTTP/1.1 to HTTP/2 cleartext upstream; required end-to-end for
  # any service that exposes gRPC alongside HTTP (Zitadel today,
  # anything kind:app backed by gRPC tomorrow). Traefik's own
  # `scheme: h2c` knob passes the HTTP/2 framing through to the pod.
  config = {
    ingress = concat(
      [
        for hostname, cfg in local.all_hostnames : {
          hostname = hostname
          service  = cfg.service
          origin_request = {
            origin_server_name = hostname
            http2_origin       = try(cfg.http2_origin, false)
          }
        }
      ],
      # Catch-all (required by Cloudflare — must be the last entry,
      # match-anything by omitting `hostname`).
      [{
        service = "http_status:404"
      }]
    )
  }
}

# ── DNS CNAME records — one per hostname ─────────────────────────────────────

resource "cloudflare_dns_record" "tunnel" {
  for_each = {
    for hostname, cfg in local.all_hostnames : hostname => cfg
    if cfg.zone_id != null
  }

  zone_id = each.value.zone_id
  name    = each.key
  # v5 dropped the `cname` attribute on the tunnel resource — construct
  # the cfargotunnel.com host ourselves. Provider docs say the format
  # is stable: `<tunnel-uuid>.cfargotunnel.com`.
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# ── Manual DNS records — declared per-domain in YAML ─────────────────────────
#
# The auto-generated CNAMEs above cover everything routed through the
# Cloudflare Tunnel (= every component declared in `envs.*.routes:`).
# Manual records here cover the rest: MX/SPF/DKIM/DMARC for mail,
# SRV records for service discovery (e.g. `_sip._udp` for sipmesh),
# apex A records when a host has a public WAN IP exposed for non-HTTP
# traffic, third-party verification TXT, etc.
#
# Schema lives on each `config/domains/<domain>.yaml` under top-level
# `dns:` — see config/domains/example.com.yaml.example for the worked
# shape. Records are domain-scoped (not env-scoped) — they describe the
# zone, not a per-env routing decision.
resource "cloudflare_dns_record" "manual" {
  for_each = local.manual_dns_records

  zone_id = each.value.zone_id
  # `name` is the FQDN form for the v5 provider; the YAML-shape short
  # name lives in `each.value.name` and only enters the for_each key
  # to keep state stable across the v4→v5 transition.
  name     = each.value.fqdn
  type     = each.value.type
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment

  # Flat `content` for A/AAAA/CNAME/MX/TXT/NS/PTR. SRV/CAA/LOC use the
  # structured `data` attribute instead — the provider rejects
  # co-presence of both, so each record specifies exactly one in YAML.
  content = each.value.data == null ? each.value.content : null

  # v5 schema: `data` is now a nested attribute (object), not a
  # dynamic block. CAA flag is a number in v5 (was string in v4) —
  # cast on the way in so YAML can keep the friendly form.
  data = each.value.data == null ? null : {
    priority = try(each.value.data.priority, null)
    weight   = try(each.value.data.weight, null)
    port     = try(each.value.data.port, null)
    target   = try(each.value.data.target, null)
    service  = try(each.value.data.service, null)
    proto    = try(each.value.data.proto, null)
    name     = try(each.value.data.name, null)
    flags    = try(tonumber(each.value.data.flags), null)
    tag      = try(each.value.data.tag, null)
    value    = try(each.value.data.value, null)
  }

  lifecycle {
    precondition {
      condition     = each.value.content != null || each.value.data != null
      error_message = "DNS record ${each.key} must declare either `content` (string) or `data` (object). See config/domains/example.com.yaml.example."
    }
    precondition {
      condition     = each.value.zone_id != null
      error_message = "DNS record ${each.key}: domain has no `cloudflare_zone_id` — set it on the domain YAML before declaring `dns:` records."
    }
  }
}
