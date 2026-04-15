# Cloudflare Zero Trust Tunnel
resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.cloudflare_account_id
  name       = "platform"
  config_src = "cloudflare"
  secret     = base64encode(var.cloudflare_tunnel_token)
}

# Remote tunnel config with all hostnames
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  config {
    ingress_rule {
      hostname = "echo.example.com"
      service  = "http://echo:8080"
    }
    ingress_rule {
      hostname = "web.example.com"
      service  = "http://web:80"
    }
    ingress_rule {
      hostname = "whoami.example.com"
      service  = "http://whoami:80"
    }
    ingress_rule {
      hostname = "traefik.example.com"
      service  = "http://traefik.traefik:9000"
    }
    ingress_rule {
      hostname = "grafana.example.com"
      service  = "http://kube-prometheus-stack-grafana.monitoring:80"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# DNS Records for all domains
resource "cloudflare_record" "echo" {
  zone_id = var.cloudflare_zone_id
  name    = "echo"
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "web" {
  zone_id = var.cloudflare_zone_id
  name    = "web"
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "whoami" {
  zone_id = var.cloudflare_zone_id
  name    = "whoami"
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "traefik" {
  zone_id = var.cloudflare_zone_id
  name    = "traefik"
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  value   = cloudflare_zero_trust_tunnel_cloudflared.main.cname
  type    = "CNAME"
  proxied = true
}
