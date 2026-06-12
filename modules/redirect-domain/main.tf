terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# Zone-wide 301 to the canonical target — done entirely in-cluster via
# a Traefik IngressRoute + RedirectRegex Middleware. No Cloudflare Rules
# or Page Rules; CF only carries the DNS + tunnel for now, and when we
# drop CF entirely (public IPv4 lands → direct A record) the same
# IngressRoute keeps working unchanged.
#
# Two K8s resources, one namespace (ingress-controller), no Service, no
# pod — Traefik does the redirect on the wire.

# RedirectRegex captures the path with `(.*)` and rebuilds the URL.
# `^https?://[^/]+/(.*)` is host-agnostic on purpose — the IngressRoute
# already restricts traffic to the source domain, so the middleware
# doesn't need to re-match the host. `${1}` (Go template form, not
# regex backref) carries the original path; Traefik passes the query
# string through automatically on redirect.
resource "kubectl_manifest" "middleware" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "redirect-${replace(var.from_domain, ".", "-")}"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      redirectRegex = {
        regex       = "^https?://[^/]+/(.*)"
        replacement = "https://${var.to_domain}/$${1}"
        permanent   = true
      }
    }
  })
}

# Matches both the apex (`Host(...)`) and any subdomain
# (`HostRegexp(...)`). Single rule with both predicates OR'd so one
# IngressRoute covers the entire zone. No backend — Traefik's
# `services` field is required by the CRD, so we point at the built-in
# `noop@internal` service that's a no-op (never reached because the
# middleware returns 301 before service dispatch).
#
# `priority: 1` pins this catch-all to the bottom of Traefik's route
# table. Traefik's default priority is the rule length, and this OR'd
# match is long enough to outrank a plain `Host(...)` rule — without
# the pin, an explicit `routes:` carve-out on a subdomain of a
# redirected zone (e.g. a link-tracking host on an otherwise
# redirect-only domain) would be shadowed by the redirect.
resource "kubectl_manifest" "ingressroute" {
  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "redirect-${replace(var.from_domain, ".", "-")}"
      namespace = var.namespace
      labels    = var.labels
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match    = "Host(`${var.from_domain}`) || HostRegexp(`^.+\\.${replace(var.from_domain, ".", "\\.")}$`)"
        kind     = "Rule"
        priority = 1
        services = [{
          name = "noop@internal"
          kind = "TraefikService"
        }]
        middlewares = [{
          name      = "redirect-${replace(var.from_domain, ".", "-")}"
          namespace = var.namespace
        }]
      }]
    }
  })

  depends_on = [kubectl_manifest.middleware]
}
