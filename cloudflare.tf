# ── Locals: flatten all project hostnames + infra services ────────────────────

locals {
  # Collect every routed hostname from every project module.
  _project_hostnames = merge([
    for _, proj in module.project : proj.hostnames
  ]...)

  # Infrastructure services that live outside project modules.
  # These use the primary cloudflare_zone_id.
  _infra_hostnames = {
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

  # The domain whose zone_id matches cloudflare_zone_id — hosts infra services.
  _infra_domain = [
    for _, config in local._domain_configs : config.name
    if try(config.cloudflare_zone_id, "") == var.cloudflare_zone_id
  ][0]

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
