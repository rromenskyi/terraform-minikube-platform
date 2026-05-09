output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "domain" {
  value = local.domain
}

output "env" {
  value = local.env
}

# Every fully-qualified hostname → which component/service it routes to.
# Consumed by the root `cloudflare.tf` to build the Cloudflare tunnel
# ingress rules and the per-host CNAME DNS records.
#
# `http2_origin` propagates from the component yaml (`http2_origin: true`)
# to the cloudflared route's `origin_request.http2_origin`, which is
# what flips cloudflared from HTTP/1.1 to HTTP/2 upstream — required
# end-to-end for any service that exposes gRPC alongside HTTP (Zitadel).
output "hostnames" {
  value = merge([
    for component, hosts in local.routes_by_component : {
      for host in hosts : host => {
        component    = component
        service      = local.component_service_urls[component]
        zone_id      = try(var.project_config.cloudflare_zone_id, null)
        http2_origin = try(local.normalized_components[component].http2_origin, false)
      }
    }
  ]...)
}

output "components" {
  value = keys(local.normalized_components)
}

# Argo CD-managed hostnames for this project. Resolved per-prefix
# against the project's domain. Each entry carries the cf_tunnel
# toggle + (when toggle is false) the node_ip the operator wants the
# A record pointing at. Consumed by the root `cloudflare.tf` to emit
# either a tunnel-routed CNAME + ingress rule (cf_tunnel=true) or an
# unproxied A record bypassing CF entirely (cf_tunnel=false).
output "argocd_hostnames" {
  value = {
    for prefix, h in var.argocd_hostnames :
    (prefix == "" ? local.domain : "${prefix}.${local.domain}") => {
      cf_tunnel = try(h.cf_tunnel, true)
      node_ip   = try(h.node_ip, "")
      zone_id   = try(var.project_config.cloudflare_zone_id, null)
      # Tunnel-routed argocd hostnames terminate at Traefik on the
      # `web` entrypoint, identical to the legacy routes pipeline.
      # Traefik then matches the Host header against an IngressRoute
      # the operator's chart applies into the project namespace via
      # Argo CD. The A-record path (cf_tunnel=false) ignores `service`
      # — the consumer skips the tunnel rule entirely.
      service = "http://traefik.ingress-controller.svc.cluster.local:80"
    }
  }
}

output "has_db" {
  value = local.needs_db
}

output "basic_auth_credentials" {
  sensitive   = true
  description = "HTTP BasicAuth credentials generated for every component in this project whose spec sets `basic_auth: true`. Keyed by component name; value is `{user, password}` in plaintext. Retrieve with: terraform output -json basic_auth_credentials | jq"
  value = {
    for name, _ in local.basic_auth_components :
    name => {
      user     = "admin"
      password = random_password.basic_auth[name].result
    }
  }
}
