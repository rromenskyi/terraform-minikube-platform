terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Cluster-wide auth gate built on `traefik-forward-auth` (thomseddon).
# Picked over oauth2-proxy because it returns 307 + Location directly
# from its auth endpoint — Traefik's ForwardAuth middleware proxies
# the response unchanged and the browser auto-follows. oauth2-proxy
# returns 401 with a redirect-HTML body which Errors middleware can't
# salvage (status is preserved, body alone won't navigate).
#
# Module-internal naming kept as `oauth2_proxy` for state continuity
# from the earlier iteration — the *behavior* is forward-auth, the
# state path is what it is.

variable "enabled" {
  description = "Deploy the auth gate. Should be tied to `services.zitadel.enabled` at the root — this module needs Zitadel as the OIDC provider."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the Deployment lives in. Expected to exist already (typically `ingress-controller`)."
  type        = string
  default     = null
}

variable "image" {
  description = "Container image. Pinned tag so the OIDC config schema doesn't shift between restarts."
  type        = string
  default     = "thomseddon/traefik-forward-auth:2.2.0"
}

variable "issuer_url" {
  description = "Zitadel public issuer URL (e.g. https://id.example.com)."
  type        = string
}

variable "auth_hostname" {
  description = "Public hostname this proxy answers on (e.g. auth.example.com). Used as the OIDC redirect URI host and as the auth-host (`/_oauth` callback lands here for every protected subdomain)."
  type        = string
}

variable "cookie_domain" {
  description = "Cookie scope. Set to the parent domain WITHOUT a leading dot (e.g. `example.com`) — traefik-forward-auth canonicalises this and emits cookies that cover every subdomain."
  type        = string
}

variable "zitadel_org_id" {
  description = "Zitadel org id the project + app live under. Caller resolves this at root via `data \"zitadel_orgs\" \"platform_org\"` and passes the value down — keeping the data source out of this module avoids the apply-time defer that consumer modules with `depends_on = [module.zitadel]` would otherwise hit and which cascades into `must be replaced` on every downstream resource."
  type        = string
}

variable "zitadel_provider_authenticated" {
  description = "True when the root TF has been handed a non-empty `TF_VAR_zitadel_pat` for the Zitadel provider. False trips the precondition so the operator gets a clear error instead of an opaque provider 'unauthenticated' on apply."
  type        = bool
  default     = false
}

variable "memory_request" {
  type    = string
  default = "16Mi"
}

variable "memory_limit" {
  type    = string
  default = "64Mi"
}

variable "cpu_request" {
  type    = string
  default = "10m"
}

variable "cpu_limit" {
  type    = string
  default = "100m"
}

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Stable resource name; used for Service, Deployment, Secret, Middleware.
  app_name = "forward-auth"
}

# ── Zitadel project + application ─────────────────────────────────────────────

resource "zitadel_project" "this" {
  for_each = local.instances

  org_id                   = var.zitadel_org_id
  name                     = local.app_name
  project_role_assertion   = false
  project_role_check       = false
  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"

  lifecycle {
    precondition {
      condition     = var.zitadel_provider_authenticated
      error_message = "forward-auth needs a Zitadel PAT. Bootstrap once: `kubectl get secret zitadel-tf-pat -n platform -o jsonpath='{.data.access_token}' | base64 -d`, paste it into `.env` as `TF_VAR_zitadel_pat=...`. See operating.md → 'Zitadel PAT bootstrap'."
    }
  }
}

resource "zitadel_application_oidc" "this" {
  for_each = local.instances

  org_id     = var.zitadel_org_id
  project_id = zitadel_project.this["enabled"].id

  name = local.app_name

  # `/_oauth` is traefik-forward-auth's hard-coded callback path on the
  # auth host (not `/oauth2/callback` like oauth2-proxy uses).
  redirect_uris             = ["https://${var.auth_hostname}/_oauth"]
  post_logout_redirect_uris = ["https://${var.auth_hostname}/"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_WEB"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"

  dev_mode                    = false
  access_token_type           = "OIDC_TOKEN_TYPE_BEARER"
  access_token_role_assertion = false
  id_token_role_assertion     = false
  id_token_userinfo_assertion = false
  clock_skew                  = "0s"
}

# ── Cookie + Secret ───────────────────────────────────────────────────────────

# Cookie-signing key. traefik-forward-auth uses HMAC-SHA256, so any
# 32+ char random is fine — pin to 32 deliberately.
resource "random_password" "cookie_secret" {
  for_each = local.instances

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "oauth2_proxy" {
  for_each = local.instances

  metadata {
    name      = local.app_name
    namespace = var.namespace
  }

  data = {
    PROVIDERS_OIDC_CLIENT_ID     = zitadel_application_oidc.this["enabled"].client_id
    PROVIDERS_OIDC_CLIENT_SECRET = zitadel_application_oidc.this["enabled"].client_secret
    SECRET                       = random_password.cookie_secret["enabled"].result
  }
}

# ── Deployment ────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "oauth2_proxy" {
  for_each = local.instances

  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = { app = local.app_name }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = local.app_name }
    }

    template {
      metadata {
        labels = { app = local.app_name }
      }

      spec {
        container {
          name  = "forward-auth"
          image = var.image

          # All non-secret config via env. Secret env (CLIENT_ID, CLIENT_SECRET,
          # SECRET) come from the Secret via env_from below.
          env {
            name  = "DEFAULT_PROVIDER"
            value = "oidc"
          }
          env {
            name  = "PROVIDERS_OIDC_ISSUER_URL"
            value = var.issuer_url
          }
          env {
            name  = "AUTH_HOST"
            value = var.auth_hostname
          }
          env {
            name  = "COOKIE_DOMAIN"
            value = var.cookie_domain
          }
          env {
            name  = "INSECURE_COOKIE"
            value = "false"
          }
          env {
            name  = "LOG_LEVEL"
            value = "debug"
          }
          # Allow any email — auth controlled by Zitadel-side roles
          # (operator can layer that in later via Zitadel's user mgmt).
          env {
            name  = "DEFAULT_ACTION"
            value = "auth"
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.oauth2_proxy["enabled"].metadata[0].name
            }
          }

          port {
            container_port = 4181
            name           = "http"
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          # No HTTP probe — traefik-forward-auth doesn't expose a /healthz
          # endpoint. Use TCP probe on the listener port.
          startup_probe {
            tcp_socket {
              port = 4181
            }
            period_seconds    = 5
            failure_threshold = 12
          }

          liveness_probe {
            tcp_socket {
              port = 4181
            }
            period_seconds    = 30
            failure_threshold = 3
          }

          readiness_probe {
            tcp_socket {
              port = 4181
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "oauth2_proxy" {
  for_each = local.instances

  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = { app = local.app_name }
  }

  spec {
    selector = { app = local.app_name }

    port {
      name        = "http"
      port        = 4181
      target_port = 4181
      protocol    = "TCP"
    }
  }
}

# ── Traefik Middlewares ──────────────────────────────────────────────────────
#
# Two middlewares emitted in `ingress-controller`. Components with
# `auth: zitadel` chain BOTH on their IngressRoute — the headers
# middleware first, then the ForwardAuth.
#
# 1) `force-https-proto` — sets `X-Forwarded-Proto: https` on the
#    request before the ForwardAuth sub-request fires. Required
#    because Cloudflare Tunnel terminates TLS at the edge and
#    cloudflared forwards plain HTTP into the cluster; Traefik
#    doesn't trust the source for X-Forwarded-* headers, so it
#    overwrites whatever cloudflared sent with its own derived
#    `http` (the in-cluster connection scheme). Without the
#    override, traefik-forward-auth's `redirectUri()` builds
#    `redirect_uri=http://auth.<domain>/_oauth`, Zitadel rejects
#    with "redirect_uri is missing in the client config" because
#    the registered URI is HTTPS-only. The alternative was either
#    to migrate every IR to the `websecure` entrypoint (breaks the
#    HTTP-01 challenge path through the tunnel) or to enable
#    `forwardedHeaders.insecure=true` on Traefik (touches shared
#    addons-chart values). Surgical header injection is the local
#    fix; the original-source-IP loss is acceptable inside a
#    single-tenant home cluster.
#
# 2) `zitadel-auth` — the ForwardAuth middleware itself.
#    traefik-forward-auth handles unauthenticated requests with a
#    307 + Location response, which Traefik's ForwardAuth proxies
#    untouched to the client; the browser follows to Zitadel.
resource "kubectl_manifest" "middleware_proto" {
  for_each = local.instances

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "force-https-proto"
      namespace = var.namespace
    }
    spec = {
      headers = {
        customRequestHeaders = {
          "X-Forwarded-Proto" = "https"
        }
      }
    }
  })
}

resource "kubectl_manifest" "middleware_forward" {
  for_each = local.instances

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "zitadel-auth"
      namespace = var.namespace
    }
    spec = {
      forwardAuth = {
        address            = "http://${kubernetes_service_v1.oauth2_proxy["enabled"].metadata[0].name}.${var.namespace}.svc.cluster.local:4181"
        trustForwardHeader = true
        authResponseHeaders = [
          "X-Forwarded-User",
        ]
      }
    }
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

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
