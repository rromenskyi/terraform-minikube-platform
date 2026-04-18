# Public Traefik dashboard IngressRoute — only emitted when an infra domain is
# resolved from the tenant YAML set. `_infra_domain` is null on a fresh clone
# before any `config/domains/*.yaml` file is created; in that state the tunnel
# cannot route a `traefik.<domain>` host and this resource is skipped rather
# than blowing up `terraform validate` with a null-in-template error.
resource "kubectl_manifest" "traefik_dashboard_public" {
  for_each = local._infra_domain == null ? toset([]) : toset(["enabled"])

  depends_on = [module.k8s]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "traefik-dashboard-public"
      namespace = "ingress-controller"
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        # coalesce against a placeholder keeps `terraform validate` happy on
        # fresh clones where `_infra_domain` is null — the resource itself is
        # gated by `for_each` above and never reaches apply in that state.
        match = "Host(`traefik.${coalesce(local._infra_domain, "unresolved.invalid")}`)"
        kind  = "Rule"
        services = [{
          kind = "TraefikService"
          name = "api@internal"
        }]
      }]
      tls = {
        certResolver = "letsencrypt-production"
      }
    }
  })
}
