output "middleware_refs" {
  description = "Ordered list of cross-namespace middleware refs an IngressRoute attaches under `spec.routes[].middlewares[]` for `auth: zitadel`. The order matters — `force-https-proto` rewrites `X-Forwarded-Proto: https` before the ForwardAuth sub-request fires, so traefik-forward-auth builds the correct `redirect_uri=https://auth...`. Null when the proxy is disabled (Zitadel off)."
  value = var.enabled ? [
    { name = "force-https-proto", namespace = var.namespace },
    { name = "zitadel-auth", namespace = var.namespace },
  ] : null
}

output "namespace" {
  value = var.namespace
}

output "service_name" {
  value = var.enabled ? kubernetes_service_v1.oauth2_proxy["enabled"].metadata[0].name : null
}
