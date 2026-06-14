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

# Matches the apex (`Host(...)`) and — when `include_subdomains` —
# every subdomain (`HostRegexp(...)`), OR'd into one rule so a single
# IngressRoute covers the whole zone. With `include_subdomains = false`
# it matches only the exact `from_domain` (single-host redirect). No
# backend — Traefik's `services` field is required by the CRD, so we
# point at the built-in `noop@internal` no-op (never reached: the
# middleware returns 301 before service dispatch).
#
# `priority` (default 2) places the rule in Traefik's route table.
# Default 2 sits just above the platform-wide `traefik-fallback` (the
# "Service is starting up" page, priority 1) and below a default-
# priority service route — so a whole-zone redirect yields to explicit
# carve-outs. NOT 1: on an equal-priority tie Traefik's winner is
# arbitrary, and at 1 the fallback page swallowed redirected zones. A
# single-host redirect that must WIN over an overlapping zone redirect
# passes a higher value (Traefik's default rule-length priority is
# unreliable when a long zone-redirect rule competes — observed live).
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
        match = var.include_subdomains ? (
          "Host(`${var.from_domain}`) || HostRegexp(`^.+\\.${replace(var.from_domain, ".", "\\.")}$`)"
        ) : "Host(`${var.from_domain}`)"
        kind     = "Rule"
        priority = var.priority
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
