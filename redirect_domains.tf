# Per-domain HTTP 301 redirects, driven from a top-level `redirect_to:`
# field in each `config/domains/<name>.yaml`. Engine emits a Traefik
# Middleware + IngressRoute per opted-in domain via the
# `modules/redirect-domain` module, and folds the apex + wildcard
# hostnames into the existing Cloudflare Tunnel + DNS CNAME machinery
# in `cloudflare.tf` (via the local maps below) so requests actually
# reach Traefik.
#
# Today the path is DNS → CF Tunnel → cloudflared in-cluster →
# Traefik :80 → IngressRoute → Middleware → 301. The CF leg is purely
# transit; flipping to direct A-records on public IPs later swaps the
# two CF locals for direct DNS without touching the module.

locals {
  # Domains that opted in. Keyed by domain name for stable for_each.
  # Skips entries where redirect_to is empty, missing, or equals the
  # domain itself (would create a redirect loop).
  _redirect_domains = {
    for name, cfg in local._domain_configs :
    name => {
      from_zone_id = cfg.cloudflare_zone_id
      from_domain  = cfg.name
      to_domain    = cfg.redirect_to
    }
    if try(cfg.redirect_to, "") != "" && try(cfg.redirect_to, "") != cfg.name
  }

  # Apex + wildcard hostnames per redirect domain, flattened to a
  # `hostname => { zone_id, service }` map for cloudflare.tf to fold
  # into its tunnel ingress + DNS CNAME for_each. Service is always
  # Traefik on plain HTTP — matches the platform-wide convention for
  # tunnel-fronted hostnames (CF terminates TLS at the edge with its
  # anycast cert; Traefik gets cleartext on the `web` entryPoint).
  redirect_tunnel_hostnames = merge([
    for _, r in local._redirect_domains : {
      "${r.from_domain}" = {
        zone_id = r.from_zone_id
        service = "http://traefik.ingress-controller.svc.cluster.local:80"
      }
      "*.${r.from_domain}" = {
        zone_id = r.from_zone_id
        service = "http://traefik.ingress-controller.svc.cluster.local:80"
      }
    }
  ]...)

  # Per-HOST 301 redirects, driven from a `redirect_hosts:` map in a
  # domain yaml: `{ <prefix>: <target-fqdn> }`. Unlike `redirect_to`
  # (whole zone → one target), this redirects ONE host to its own
  # target, overriding the zone redirect for that host. Use for
  # campaign link hosts that live on an otherwise redirect-only zone
  # but must land on a different app (e.g. `dev-links.l1promo.com` →
  # `dev.lineoneagent.com` while the rest of l1promo.com → the prod
  # site). Keyed by FQDN for a stable for_each.
  _redirect_hosts = merge([
    for name, cfg in local._domain_configs : {
      for prefix, target in try(cfg.redirect_hosts, {}) :
      "${prefix}.${cfg.name}" => {
        zone_id   = cfg.cloudflare_zone_id
        from_host = "${prefix}.${cfg.name}"
        to_domain = target
      }
    }
  ]...)

  # Tunnel/DNS wiring for the per-host redirects — just the host itself
  # (no wildcard; a single-host redirect owns exactly one name).
  redirect_host_tunnel_hostnames = {
    for fqdn, r in local._redirect_hosts :
    fqdn => {
      zone_id = r.zone_id
      service = "http://traefik.ingress-controller.svc.cluster.local:80"
    }
  }
}

# One in-cluster Traefik IngressRoute + RedirectRegex Middleware per
# opted-in domain.
module "redirect_domain" {
  source   = "./modules/redirect-domain"
  for_each = local._redirect_domains

  from_domain = each.value.from_domain
  to_domain   = each.value.to_domain
  labels      = module.platform_label.tags
}

# One in-cluster redirect per `redirect_hosts:` entry. Matches the exact
# host only (`include_subdomains = false`) at an explicit high priority
# so it wins over any overlapping zone redirect on the same domain
# (Traefik's default rule-length priority proved unreliable for this —
# a long zone-redirect rule outranked a default-priority carve-out).
module "redirect_host" {
  source   = "./modules/redirect-domain"
  for_each = local._redirect_hosts

  from_domain        = each.value.from_host
  to_domain          = each.value.to_domain
  include_subdomains = false
  priority           = 100
  labels             = module.platform_label.tags
}

output "redirect_domains" {
  description = "Map of opted-in redirect domains keyed by source name; value carries the target domain. Reference-only — operator can grep for `<from>` in `kubectl get ingressroute -A` to find the matching IngressRoute."
  value = {
    for name, r in local._redirect_domains :
    name => {
      from = r.from_domain
      to   = r.to_domain
    }
  }
}
