# ── Native-client listeners (IMAPS 993 + submission 465) ──────────────────────
#
# Publishes Stalwart's client ports on `var.client_listen_ip` (typically the
# node's PUBLIC IP) for desktop/mobile mail clients. A tiny hostNetwork socat
# pod binds the host IP and terminates client TLS with the public cert
# (`stalwart-client-tls`), re-originating TLS to the in-cluster Stalwart Service
# (its self-signed cert stays internal). Stalwart itself is untouched (no
# restart, no extra host interfaces on its own pod). Gated on `client_listen_ip`.
resource "kubernetes_deployment_v1" "stalwart_client_proxy" {
  for_each = var.client_listen_ip != "" ? local.instances : toset([])

  metadata {
    name      = "stalwart-client-proxy"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart-client-proxy" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "stalwart-client-proxy" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "stalwart-client-proxy" })
      }

      spec {
        host_network  = true
        dns_policy    = "ClusterFirstWithHostNet"
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key                = toleration.value.key
            operator           = toleration.value.operator
            value              = toleration.value.value
            effect             = toleration.value.effect
            toleration_seconds = toleration.value.toleration_seconds
          }
        }

        # IMAPS 993 — TLS-terminate with the public cert (when issued), re-TLS to
        # Stalwart; else raw passthrough to Stalwart's self-signed cert.
        container {
          name  = "socat-imaps"
          image = "alpine/socat:1.8.0.0"

          args = length(var.client_cert_dns_names) > 0 ? [
            "OPENSSL-LISTEN:993,bind=${var.client_listen_ip},cert=/certs/tls.crt,key=/certs/tls.key,verify=0,fork,reuseaddr",
            "OPENSSL:stalwart.${var.namespace}.svc.cluster.local:993,verify=0",
            ] : [
            "TCP-LISTEN:993,bind=${var.client_listen_ip},fork,reuseaddr",
            "TCP:stalwart.${var.namespace}.svc.cluster.local:993",
          ]

          dynamic "volume_mount" {
            for_each = length(var.client_cert_dns_names) > 0 ? toset(["cert"]) : toset([])
            content {
              name       = "client-tls"
              mount_path = "/certs"
              read_only  = true
            }
          }

          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }

        # SMTP submission 465 — same TLS-terminate/passthrough as IMAPS.
        container {
          name  = "socat-submission"
          image = "alpine/socat:1.8.0.0"

          args = length(var.client_cert_dns_names) > 0 ? [
            "OPENSSL-LISTEN:465,bind=${var.client_listen_ip},cert=/certs/tls.crt,key=/certs/tls.key,verify=0,fork,reuseaddr",
            "OPENSSL:stalwart.${var.namespace}.svc.cluster.local:465,verify=0",
            ] : [
            "TCP-LISTEN:465,bind=${var.client_listen_ip},fork,reuseaddr",
            "TCP:stalwart.${var.namespace}.svc.cluster.local:465",
          ]

          dynamic "volume_mount" {
            for_each = length(var.client_cert_dns_names) > 0 ? toset(["cert"]) : toset([])
            content {
              name       = "client-tls"
              mount_path = "/certs"
              read_only  = true
            }
          }

          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }

        dynamic "volume" {
          for_each = length(var.client_cert_dns_names) > 0 ? toset(["cert"]) : toset([])
          content {
            name = "client-tls"
            secret {
              secret_name = "stalwart-client-tls"
            }
          }
        }
      }
    }
  }
}

# ── LAN-only admin listener (mailadmin.<domain>:443) ──────────────────────────
#
# Stalwart serves its webadmin ONLY at the bare `/admin` path and ignores
# X-Forwarded-Prefix, so the obscurity-prefix IngressRoute 404s and can't be
# fixed with StripPrefix. Instead, publish Stalwart's whole HTTP surface on a
# dedicated hostname bound to the node's LAN IP: a hostNetwork socat pod
# terminates TLS with a real cert (`stalwart-admin-tls`) on `admin_listen_ip:443`
# and forwards plaintext to Stalwart's in-cluster HTTP (8080) — the same hop
# Traefik/Cloudflare already use. Reachable only from the LAN (bound to the
# private interface; host firewall admits 443 from the LAN subnet only) — the
# admin UI never touches the internet, and OIDC auth still gates it. Gated on
# both `admin_hostname` and `admin_listen_ip`.
resource "kubectl_manifest" "stalwart_admin_cert" {
  for_each = var.admin_hostname != "" && var.admin_listen_ip != "" ? local.instances : toset([])

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "stalwart-admin-tls"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      secretName = "stalwart-admin-tls"
      dnsNames   = [var.admin_hostname]
      issuerRef = {
        name  = var.client_cert_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })
}

resource "kubernetes_deployment_v1" "stalwart_admin_proxy" {
  for_each = var.admin_hostname != "" && var.admin_listen_ip != "" ? local.instances : toset([])

  metadata {
    name      = "stalwart-admin-proxy"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart-admin-proxy" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "stalwart-admin-proxy" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "stalwart-admin-proxy" })
      }

      spec {
        host_network  = true
        dns_policy    = "ClusterFirstWithHostNet"
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key                = toleration.value.key
            operator           = toleration.value.operator
            value              = toleration.value.value
            effect             = toleration.value.effect
            toleration_seconds = toleration.value.toleration_seconds
          }
        }

        # HTTPS 443 on the LAN IP — TLS-terminate with the admin cert, forward
        # plaintext to Stalwart's in-cluster HTTP (8080), the same hop Traefik
        # and Cloudflare already terminate in front of.
        container {
          name  = "socat-admin"
          image = "alpine/socat:1.8.0.0"

          args = [
            "OPENSSL-LISTEN:443,bind=${var.admin_listen_ip},cert=/certs/tls.crt,key=/certs/tls.key,verify=0,fork,reuseaddr",
            "TCP:stalwart.${var.namespace}.svc.cluster.local:8080",
          ]

          volume_mount {
            name       = "admin-tls"
            mount_path = "/certs"
            read_only  = true
          }

          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }

        volume {
          name = "admin-tls"
          secret {
            secret_name = "stalwart-admin-tls"
          }
        }
      }
    }
  }
}
