# Cloudflare Zero Trust Tunnel
resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = "platform"
  config_src = "cloudflare"
  secret     = base64encode(var.cloudflare_tunnel_token)
}

locals {
  # Tunnel ingress rules keyed by DNS label. The `service` value is the
  # in-cluster URL the tunnel forwards to; the CNAME record for each key
  # below is created in a single for_each cloudflare_record resource.
  cloudflare_tunnel_routes = {
    echo    = "http://echo:8080"
    web     = "http://web:80"
    whoami  = "http://whoami:80"
    traefik = "http://traefik.traefik:9000"
    grafana = "http://kube-prometheus-stack-grafana.monitoring:80"
  }
}

# Remote tunnel config with all hostnames
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  config {
    dynamic "ingress_rule" {
      for_each = local.cloudflare_tunnel_routes
      content {
        hostname = "${ingress_rule.key}.${var.cloudflare_tunnel_domain}"
        service  = ingress_rule.value
      }
    }

    # Terminal catch-all must come last.
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# DNS records for each tunnel route — one CNAME per hostname, all pointing
# at the tunnel's synthetic hostname.
resource "cloudflare_record" "tunnel" {
  for_each = local.cloudflare_tunnel_routes

  zone_id = var.cloudflare_zone_id
  name    = each.key
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}

# Graceful state migration from the previous `cloudflare_record.<name>`
# shape to `cloudflare_record.tunnel["<name>"]`. `moved` blocks tell
# Terraform to rename in-state instead of destroy+create.
moved {
  from = cloudflare_record.echo
  to   = cloudflare_record.tunnel["echo"]
}

moved {
  from = cloudflare_record.web
  to   = cloudflare_record.tunnel["web"]
}

moved {
  from = cloudflare_record.whoami
  to   = cloudflare_record.tunnel["whoami"]
}

moved {
  from = cloudflare_record.traefik
  to   = cloudflare_record.tunnel["traefik"]
}

moved {
  from = cloudflare_record.grafana
  to   = cloudflare_record.tunnel["grafana"]
}
