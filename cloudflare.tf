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
  account_id = var.cloudflare_account_id
  name       = "platform"
  config_src = "cloudflare"
  secret     = base64encode(random_password.cloudflare_tunnel_secret.result)
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

  config {
    dynamic "ingress_rule" {
      for_each = local.all_hostnames
      content {
        hostname = ingress_rule.key
        service  = ingress_rule.value.service

        # End-to-end TLS to Traefik. `origin_server_name` sets the SNI
        # cloudflared presents on the upstream TLS handshake — without
        # it cloudflared would SNI as the service-URL host
        # (`traefik.ingress-controller.svc.cluster.local`), Traefik
        # would fall back to its self-signed default cert, and
        # cloudflared would reject it. Setting SNI to the public
        # hostname lets Traefik serve the correct Let's Encrypt cert,
        # which cloudflared validates cleanly.
        #
        # `http2_origin` is opt-in via the component yaml — flips
        # cloudflared from HTTP/1.1 to HTTP/2 cleartext upstream;
        # required end-to-end for any service that exposes gRPC
        # alongside HTTP (Zitadel today, anything kind:app backed by
        # gRPC tomorrow). Traefik's own `scheme: h2c` knob passes the
        # HTTP/2 framing through to the pod.
        origin_request {
          origin_server_name = ingress_rule.key
          http2_origin       = try(ingress_rule.value.http2_origin, false)
        }
      }
    }

    # Catch-all (required by Cloudflare)
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# ── DNS CNAME records — one per hostname ─────────────────────────────────────

resource "cloudflare_record" "tunnel" {
  for_each = {
    for hostname, cfg in local.all_hostnames : hostname => cfg
    if cfg.zone_id != null
  }

  zone_id = each.value.zone_id
  name    = each.key
  content = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
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
resource "cloudflare_record" "manual" {
  for_each = local.manual_dns_records

  zone_id  = each.value.zone_id
  name     = each.value.name
  type     = each.value.type
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment

  # Flat `content` for A/AAAA/CNAME/MX/TXT/NS/PTR. SRV/CAA/LOC use the
  # structured `data` block instead — the provider rejects co-presence
  # of both, so each record specifies exactly one in YAML.
  content = each.value.data == null ? each.value.content : null

  dynamic "data" {
    for_each = each.value.data == null ? [] : [each.value.data]
    content {
      priority = try(data.value.priority, null)
      weight   = try(data.value.weight, null)
      port     = try(data.value.port, null)
      target   = try(data.value.target, null)
      service  = try(data.value.service, null)
      proto    = try(data.value.proto, null)
      name     = try(data.value.name, null)
      flags    = try(data.value.flags, null)
      tag      = try(data.value.tag, null)
      value    = try(data.value.value, null)
    }
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
