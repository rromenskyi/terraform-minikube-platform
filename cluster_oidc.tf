# Public OIDC discovery for the cluster — Workload Identity Federation
# bridge.
#
# Exposes kube-apiserver's two anonymous OIDC discovery endpoints
#
#   GET /.well-known/openid-configuration   → discovery document
#   GET /openid/v1/jwks                     → public key set
#
# at a public hostname (`services.cluster_oidc.external_hostname`) so
# external workload-identity verifiers (GCP STS, AWS STS, Azure
# Workload Identity, generic OIDC trust policies) can fetch JWKS to
# verify ServiceAccount-token signatures and let pods running in this
# cluster authenticate to external IAM systems without long-lived
# keys.
#
# Trust model: the discovery doc + JWKS are PUBLIC by OIDC design —
# they contain no secret material. Exposing them publicly does not
# weaken cluster security; it only enables external verifiers to do
# their job. Knowing the cluster's OIDC discovery URL slightly
# increases fingerprintability of the k8s setup; acceptable trade
# for WIF capability.
#
# This module does NOT make kube-apiserver publicly reachable. Only
# those two specific paths are proxied; everything else is unreachable
# from outside the cluster (Traefik IngressRoute matches paths
# strictly).
#
# Two prerequisites the engine cannot enforce (require operator
# action):
#
#   1. kube-apiserver must mint tokens with `iss` claim matching the
#      public URL (i.e. `https://${external_hostname}`). Default k3s
#      issuer is `https://kubernetes.default.svc.cluster.local`,
#      which GCP/AWS STS cannot reach. Operator adds dual-issuer
#      config to `/etc/rancher/k3s/config.yaml.d/oidc.yaml` on each
#      control-plane node + `systemctl restart k3s`:
#
#        kube-apiserver-arg:
#          - "service-account-issuer=https://k8s-oidc.<domain>"
#          - "service-account-issuer=https://kubernetes.default.svc.cluster.local"
#
#      First issuer becomes default for new tokens; second keeps
#      legacy validators working. Roll restart one node at a time.
#
#   2. External verifier (GCP WIF pool / AWS OIDC provider) must be
#      configured to trust `https://${external_hostname}` as the
#      issuer, with audience and attribute mapping per the consumer's
#      need. Outside this engine's scope.

check "cluster_oidc_external_hostname_set" {
  assert {
    condition     = !local.platform.services.cluster_oidc.enabled || local.platform.services.cluster_oidc.external_hostname != ""
    error_message = "services.cluster_oidc.enabled = true requires services.cluster_oidc.external_hostname to be set (e.g. `k8s-oidc.example.com`). The hostname must match the `--service-account-issuer` value the operator configured on kube-apiserver, otherwise external verifiers will reject tokens with issuer/discovery URL mismatch."
  }
}

locals {
  _cluster_oidc_enabled = local.platform.services.cluster_oidc.enabled ? toset(["enabled"]) : toset([])

  _cluster_oidc_nginx_conf = <<-NGINX
    events {}

    http {
      access_log /dev/stdout;
      error_log  /dev/stderr;

      # Restrict to ONLY the two anonymous discovery endpoints. Any
      # other path returns 404 — no risk of accidentally proxying
      # mutating apiserver requests through this public ingress.
      server {
        listen 8080;
        server_name _;

        location = /.well-known/openid-configuration {
          proxy_pass https://kubernetes.default.svc:443;
          proxy_ssl_verify on;
          proxy_ssl_trusted_certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt;
          proxy_ssl_server_name on;
          proxy_ssl_name kubernetes.default.svc;
          proxy_set_header Host kubernetes.default.svc;
          proxy_set_header Authorization "";
        }

        location = /openid/v1/jwks {
          proxy_pass https://kubernetes.default.svc:443;
          proxy_ssl_verify on;
          proxy_ssl_trusted_certificate /var/run/secrets/kubernetes.io/serviceaccount/ca.crt;
          proxy_ssl_server_name on;
          proxy_ssl_name kubernetes.default.svc;
          proxy_set_header Host kubernetes.default.svc;
          proxy_set_header Authorization "";
        }

        location / {
          return 404 "Not Found\n";
          add_header Content-Type "text/plain";
        }
      }
    }
  NGINX
}

# Namespace for the OIDC proxy.
resource "kubernetes_namespace_v1" "cluster_oidc" {
  for_each = local._cluster_oidc_enabled

  metadata {
    name = "k8s-oidc"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cluster-oidc-proxy"
    }
  }
}

# Bind system:anonymous to the cluster's built-in discovery role so
# the two endpoints respond to unauthenticated GETs. k8s ships
# `system:service-account-issuer-discovery` ClusterRole pre-bound to
# `system:serviceaccounts` Group — fine for in-cluster pods, but our
# proxy needs to forward unauthenticated requests (we explicitly
# strip the SA-token auth header in nginx to avoid leaking the
# proxy's SA token in the upstream call).
#
# Security: the role grants only GET on the two discovery paths. No
# other apiserver capability is exposed.
resource "kubernetes_cluster_role_binding_v1" "anonymous_discovery" {
  for_each = local._cluster_oidc_enabled

  metadata {
    name = "cluster-oidc-anonymous-discovery"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cluster-oidc-proxy"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:service-account-issuer-discovery"
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = "system:anonymous"
  }
}

resource "kubernetes_config_map_v1" "cluster_oidc_nginx" {
  for_each = local._cluster_oidc_enabled

  metadata {
    name      = "nginx-conf"
    namespace = kubernetes_namespace_v1.cluster_oidc["enabled"].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cluster-oidc-proxy"
    }
  }

  data = {
    "nginx.conf" = local._cluster_oidc_nginx_conf
  }
}

resource "kubernetes_deployment_v1" "cluster_oidc_proxy" {
  for_each = local._cluster_oidc_enabled

  metadata {
    name      = "oidc-proxy"
    namespace = kubernetes_namespace_v1.cluster_oidc["enabled"].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cluster-oidc-proxy"
      "app.kubernetes.io/name"       = "oidc-proxy"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "oidc-proxy"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = "oidc-proxy"
          "app.kubernetes.io/component" = "cluster-oidc-proxy"
        }
        annotations = {
          "checksum/nginx-conf" = sha256(local._cluster_oidc_nginx_conf)
        }
      }
      spec {
        node_selector = local.platform.services.cluster_oidc.node_selector

        dynamic "toleration" {
          for_each = local.platform.services.cluster_oidc.tolerations
          content {
            key      = try(toleration.value.key, null)
            operator = try(toleration.value.operator, "Exists")
            value    = try(toleration.value.value, null)
            effect   = try(toleration.value.effect, null)
          }
        }

        container {
          name              = "nginx"
          image             = "nginx:1.27-alpine"
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }

          # nginx writes a small tmp during request handling — without
          # this k8s pod can't run with readOnlyRootFilesystem set.
          volume_mount {
            name       = "cache"
            mount_path = "/var/cache/nginx"
          }

          volume_mount {
            name       = "run"
            mount_path = "/var/run"
          }

          readiness_probe {
            http_get {
              path = "/.well-known/openid-configuration"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }

          liveness_probe {
            tcp_socket {
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 20
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "64Mi"
            }
          }

          security_context {
            run_as_non_root            = true
            run_as_user                = 101
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.cluster_oidc_nginx["enabled"].metadata[0].name
          }
        }

        volume {
          name = "cache"
          empty_dir {}
        }

        volume {
          name = "run"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "cluster_oidc_proxy" {
  for_each = local._cluster_oidc_enabled

  metadata {
    name      = "oidc-proxy"
    namespace = kubernetes_namespace_v1.cluster_oidc["enabled"].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "cluster-oidc-proxy"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = "oidc-proxy"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# Traefik IngressRoute — emitted by kubectl_manifest because the
# Traefik CRDs aren't in the kubernetes provider's typed schema.
# Routes ONLY the two OIDC discovery paths; any other URL on this
# hostname returns 404 from nginx + Traefik never matches it.
resource "kubectl_manifest" "cluster_oidc_ingressroute" {
  for_each = local._cluster_oidc_enabled

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "oidc-proxy"
      namespace = kubernetes_namespace_v1.cluster_oidc["enabled"].metadata[0].name
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "cluster-oidc-proxy"
      }
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${local.platform.services.cluster_oidc.external_hostname}`) && (Path(`/.well-known/openid-configuration`) || Path(`/openid/v1/jwks`))"
          kind  = "Rule"
          services = [
            {
              name      = kubernetes_service_v1.cluster_oidc_proxy["enabled"].metadata[0].name
              port      = 80
              namespace = kubernetes_namespace_v1.cluster_oidc["enabled"].metadata[0].name
            }
          ]
        }
      ]
      tls = {
        certResolver = "letsencrypt"
      }
    }
  })
}

# Cloudflare Tunnel ingress rule + DNS CNAME — emit through the same
# tunnel/DNS plumbing as every other public hostname. The catch-all
# entry in the tunnel config is always last; we prepend ours via the
# existing `local.all_hostnames` machinery by extending that map.
#
# Rather than wiring into the existing project/hostname plumbing
# (which assumes a tenant project context), emit a dedicated CNAME +
# tunnel ingress for cluster_oidc. The hostname is operator-owned;
# zone_id is derived by matching the hostname's suffix against
# operator-declared domain yamls.
locals {
  _cluster_oidc_zone_id = local.platform.services.cluster_oidc.enabled ? try(
    [
      for name, cfg in local._domain_configs :
      cfg.cloudflare_zone_id
      if endswith(local.platform.services.cluster_oidc.external_hostname, ".${name}") || local.platform.services.cluster_oidc.external_hostname == name
    ][0],
    ""
  ) : ""
}

check "cluster_oidc_hostname_in_known_zone" {
  assert {
    condition     = !local.platform.services.cluster_oidc.enabled || local._cluster_oidc_zone_id != ""
    error_message = "services.cluster_oidc.external_hostname `${local.platform.services.cluster_oidc.external_hostname}` does not match any zone declared in `config/domains/*.yaml`. Add the parent domain's yaml (with `cloudflare_zone_id`) before enabling cluster_oidc."
  }
}

resource "cloudflare_dns_record" "cluster_oidc_proxy" {
  for_each = local._cluster_oidc_enabled

  zone_id = local._cluster_oidc_zone_id
  name    = local.platform.services.cluster_oidc.external_hostname
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

output "cluster_oidc_issuer_url" {
  description = "Public OIDC issuer URL for the cluster. The value an external Workload Identity verifier (GCP WIF, AWS OIDC provider, etc.) configures as `issuer`. Discovery and JWKS land at `<issuer_url>/.well-known/openid-configuration` and `<issuer_url>/openid/v1/jwks`. Empty when cluster_oidc disabled."
  value       = local.platform.services.cluster_oidc.enabled ? "https://${local.platform.services.cluster_oidc.external_hostname}" : ""
}
