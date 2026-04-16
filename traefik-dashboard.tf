resource "kubectl_manifest" "traefik_dashboard_public" {
  depends_on = [module.k8s]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "traefik-dashboard-public"
      namespace = "ingress-controller"
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match = "Host(`traefik.${var.cloudflare_tunnel_domain}`)"
        kind  = "Rule"
        services = [{
          kind = "TraefikService"
          name = "api@internal"
        }]
      }]
    }
  })
}
