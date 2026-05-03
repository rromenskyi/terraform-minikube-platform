# Branded fallback page for requests Traefik cannot route to a healthy
# backend.
#
# Symptom we're closing: when an operator-rolled Deployment has zero
# Ready endpoints (mid-restart, evicted, image pull, or the operator
# just hasn't shipped a backend for a route yet), Traefik responds
# with the default `404 page not found` / `no available server`. From
# the public side that reads as "the entire platform is down" or
# "this isn't a real service" — visible during normal rollouts of
# tenant components.
#
# The fix is a tiny static `nginx:alpine` Deployment in the
# `ingress-controller` namespace serving a branded HTML page, plus
# two Traefik primitives:
#
#   1. A `Middleware` of kind `errors`. Attached anywhere a service
#      can return upstream-down style codes (502/503/504), it
#      replaces Traefik's default error body with `/index.html` from
#      this Deployment. Wiring it onto every project IngressRoute is
#      out of scope here — that's a follow-up touch on
#      `modules/project`. The middleware exists so the operator can
#      opt routes in by name later.
#
#   2. A catch-all `IngressRoute` matching any host on `web` +
#      `websecure`, with explicit `priority = 1` so it's always the
#      last route Traefik considers. Hostnames that reach the cluster
#      (i.e. cloudflared has them in its ingress map) but have no
#      matching IngressRoute fall through to this one and get the
#      branded page instead of the bare Traefik 404.
#
# The page intentionally tells the visitor "service is starting up"
# rather than "404": the most common cause is mid-rollout, and the
# wording shouldn't suggest the URL is wrong when it isn't.

locals {
  fallback_app_name  = "traefik-fallback"
  fallback_namespace = "ingress-controller"

  # Single self-contained HTML — no external assets so the page works
  # the same whether the visitor reaches it via Traefik fallback,
  # direct Service curl, or kubectl port-forward.
  fallback_html = <<-EOT
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="robots" content="noindex,nofollow">
      <title>Service is starting up</title>
      <style>
        :root { color-scheme: light dark; }
        html, body { height: 100%; margin: 0; }
        body {
          display: flex; align-items: center; justify-content: center;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                       Roboto, Helvetica, Arial, sans-serif;
          background: #0e1117; color: #e6edf3;
          padding: 2rem;
        }
        .card {
          max-width: 32rem; text-align: center;
        }
        h1 {
          font-size: 1.5rem; font-weight: 600; margin: 0 0 0.75rem;
        }
        p {
          font-size: 0.95rem; line-height: 1.5; margin: 0.5rem 0;
          color: #8b949e;
        }
        .hint {
          margin-top: 1.5rem; font-size: 0.8rem; color: #6e7681;
        }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Service is starting up</h1>
        <p>This service is briefly unavailable — likely a rolling
        update or a pod restart in flight. It should be back in a
        moment.</p>
        <p class="hint">If this persists, the service may be
        intentionally offline or not yet provisioned.</p>
      </div>
    </body>
    </html>
  EOT
}

resource "kubernetes_config_map_v1" "fallback_html" {
  metadata {
    name      = "${local.fallback_app_name}-html"
    namespace = local.fallback_namespace
    labels = {
      "app.kubernetes.io/name"       = local.fallback_app_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "index.html" = local.fallback_html
  }
}

resource "kubernetes_deployment_v1" "fallback" {
  depends_on = [module.addons]

  metadata {
    name      = local.fallback_app_name
    namespace = local.fallback_namespace
    labels = {
      "app.kubernetes.io/name"       = local.fallback_app_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = local.fallback_app_name }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = local.fallback_app_name }
        # Bounce the pod on every HTML edit so the rendered page
        # actually reflects the ConfigMap content without an explicit
        # `kubectl rollout restart`.
        annotations = {
          "platform.local/html-hash" = sha1(local.fallback_html)
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 80
            name           = "http"
          }

          volume_mount {
            name       = "html"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }

          # Tiny by design — this is one static file served to a
          # handful of misrouted requests during deploys, not a
          # production workload.
          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "50m", memory = "32Mi" }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 1
            period_seconds        = 5
          }
        }

        volume {
          name = "html"
          config_map {
            name = kubernetes_config_map_v1.fallback_html.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "fallback" {
  metadata {
    name      = local.fallback_app_name
    namespace = local.fallback_namespace
    labels = {
      "app.kubernetes.io/name"       = local.fallback_app_name
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    selector = { "app.kubernetes.io/name" = local.fallback_app_name }
    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Traefik `errors` middleware. Attach to any IngressRoute whose
# upstream can return 502/503/504 to swap the default Traefik error
# body for our branded page. Currently unattached — wiring on tenant
# IngressRoutes is a follow-up in `modules/project`.
resource "kubectl_manifest" "fallback_errors_middleware" {
  depends_on = [module.addons]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "${local.fallback_app_name}-errors"
      namespace = local.fallback_namespace
    }
    spec = {
      errors = {
        status = ["502", "503", "504"]
        service = {
          name = kubernetes_service_v1.fallback.metadata[0].name
          port = 80
        }
        query = "/"
      }
    }
  })
}

# Catch-all IngressRoute. `priority = 1` ensures Traefik considers
# every more-specific route first; this fires only when nothing else
# matched. The `web` and `websecure` entrypoints are both covered so
# fallback works whether the request landed before or after the
# tenant router upgraded to TLS.
resource "kubectl_manifest" "fallback_ingressroute" {
  depends_on = [
    module.addons,
    kubernetes_service_v1.fallback,
  ]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = local.fallback_app_name
      namespace = local.fallback_namespace
    }
    spec = {
      entryPoints = ["web", "websecure"]
      routes = [{
        match    = "PathPrefix(`/`)"
        kind     = "Rule"
        priority = 1
        services = [{
          name      = kubernetes_service_v1.fallback.metadata[0].name
          namespace = local.fallback_namespace
          port      = 80
        }]
      }]
    }
  })
}
