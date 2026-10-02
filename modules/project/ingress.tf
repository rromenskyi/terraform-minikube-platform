# ── IngressRoutes ─────────────────────────────────────────────────────────────
#
# One IngressRoute per component, carrying every route that points at it:
# one rule for all of its whole-host routes, plus one rule per path-scoped
# route. A component is deployed only because at least one route targets
# it, so every IngressRoute has at least one rule.
#
# Path-scoped rules carry an explicit priority above any whole-host rule
# (Traefik's default priority is the rule's string length, which proved
# unreliable for carve-outs — see redirect_domains.tf), and a longer path
# outranks a shorter one on the same host. `Path || PathPrefix(<p>/)`
# matches on segment boundaries, so `/api` does not also catch `/apix`.

resource "kubectl_manifest" "ingressroute" {
  for_each = local.routes_by_component

  depends_on = [module.component, kubectl_manifest.basic_auth_middleware, kubectl_manifest.rate_limit_middleware]

  lifecycle {
    precondition {
      condition = alltrue([
        for r in local.path_routes_by_component[each.key] :
        can(regex("^(/[A-Za-z0-9._~-]+)+$", r.path))
      ])
      error_message = "component '${each.key}' in project '${local.namespace}' has a path-scoped route with an invalid path: ${jsonencode([for r in local.path_routes_by_component[each.key] : r.path])}. Use `<host-prefix>/<segment>[/<segment>...]` route keys (e.g. \"/api\" or \"www/api/v1\") — non-empty segments of [A-Za-z0-9._~-]."
    }
  }

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = each.key
      namespace = local.namespace
      labels    = module.project_label.tags
    }
    spec = merge(
      {
        entryPoints = local.ir_entry_points[each.key]
        routes = concat(
          length(each.value) > 0 ? [merge(
            {
              match    = join(" || ", [for d in each.value : "Host(`${d}`)"])
              kind     = "Rule"
              services = [local.ir_service_refs[each.key]]
            },
            length(local.ir_middlewares[each.key]) > 0 ? { middlewares = local.ir_middlewares[each.key] } : {},
          )] : [],
          # Rate-limited paths on the whole-host routes. The priority sits
          # above every path-scoped route so the limit cannot be skipped.
          length(each.value) == 0 ? [] : [
            for rl in values(local.rate_limits) : {
              match = join(" && ", concat(
                ["(${join(" || ", [for d in each.value : "Host(`${d}`)"])})", "Path(`${rl.path}`)"],
                length(rl.methods) > 0 ? ["(${join(" || ", [for m in rl.methods : "Method(`${m}`)"])})"] : [],
              ))
              kind        = "Rule"
              priority    = 20000 + length(rl.path)
              services    = [local.ir_service_refs[each.key]]
              middlewares = concat([{ name = rl.name }], local.ir_middlewares[each.key])
            } if rl.component == each.key
          ],
          [
            for r in local.path_routes_by_component[each.key] : merge(
              {
                match    = "Host(`${r.host}`) && (Path(`${r.path}`) || PathPrefix(`${r.path}/`))"
                kind     = "Rule"
                priority = 10000 + length(r.path)
                services = [local.ir_service_refs[each.key]]
              },
              length(local.ir_middlewares[each.key]) > 0 ? { middlewares = local.ir_middlewares[each.key] } : {},
            )
          ],
        )
      },
      # `tls` only applies on the `websecure` entrypoint; omitting the
      # block on `web` keeps the CRD valid and avoids Traefik rejecting the
      # route with "cannot set TLS options on non-TLS entry point".
      contains(local.ir_entry_points[each.key], "websecure")
      ? { tls = { certResolver = "letsencrypt-production" } }
      : {}
    )
  })
}
