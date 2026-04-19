# ── Locals: flatten all project hostnames + infra services ────────────────────

locals {
  # Collect every routed hostname from every project module.
  _project_hostnames = merge([
    for _, proj in module.project : proj.hostnames
  ]...)

  # The domain whose zone_id matches cloudflare_zone_id — hosts infra services.
  # Nullable: a fresh clone with no tenant YAML files yet still has to plan and
  # `terraform validate`. When no domain matches, infra hostnames collapse to
  # an empty map and the tunnel config reduces to the catch-all rule.
  _infra_domain_candidates = [
    for _, config in local._domain_configs : config.name
    if try(config.cloudflare_zone_id, "") == var.cloudflare_zone_id
  ]
  _infra_domain = length(local._infra_domain_candidates) > 0 ? local._infra_domain_candidates[0] : null

  # Infrastructure services that live outside project modules.
  # These use the primary cloudflare_zone_id. Empty when no matching domain
  # is configured yet.
  _infra_hostnames = local._infra_domain == null ? {} : {
    "traefik.${local._infra_domain}" = {
      component = "traefik"
      service   = "http://traefik.ingress-controller.svc.cluster.local:80"
      zone_id   = var.cloudflare_zone_id
    }
    "grafana.${local._infra_domain}" = {
      component = "grafana"
      service   = "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80"
      zone_id   = var.cloudflare_zone_id
    }
  }

  # All hostnames: projects + infra — single source of truth for tunnel + DNS.
  all_hostnames = merge(local._project_hostnames, local._infra_hostnames)
}

# ── Cloudflare Zero Trust Tunnel ─────────────────────────────────────────────

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = "platform"
  config_src = "cloudflare"
  secret     = base64encode(var.cloudflare_tunnel_secret)
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
