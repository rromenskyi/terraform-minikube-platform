# ── SMTP relay forwarder ──────────────────────────────────────────────────────
#
# Tiny socat pod whose only job is to listen on the WireGuard interface
# address and forward to the in-cluster Stalwart SMTP Service. Runs with
# hostNetwork=true because it MUST bind to a specific host IP (the WG
# address); doing this in the Stalwart pod itself would put Stalwart's
# HTTP listener on every host interface as a side-effect, which we
# explicitly want to avoid.
resource "kubernetes_deployment_v1" "stalwart_smtp_relay" {
  for_each = local.instances

  metadata {
    name      = "stalwart-smtp-relay"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart-smtp-relay" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "stalwart-smtp-relay" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "stalwart-smtp-relay" })
      }

      spec {
        host_network = true
        dns_policy   = "ClusterFirstWithHostNet"

        # `var.smtp_relay_listen_ip` may resolve only on a specific
        # node (e.g. when the operator's deployment binds the inbound
        # forwarder to an interface that lives on one host). Pin
        # there via `var.node_selector`; without the selector and on
        # a multi-node cluster, the scheduler can land this pod
        # where the bind address doesn't exist and socat fails at
        # start with "Cannot assign requested address".
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

        container {
          name  = "socat"
          image = "alpine/socat:1.8.0.0"

          args = [
            "TCP-LISTEN:25,bind=${var.smtp_relay_listen_ip},fork,reuseaddr",
            "TCP:stalwart-smtp.${var.namespace}.svc.cluster.local:25",
          ]

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
      }
    }
  }
}

# Public cert for the native-client listeners. cert-manager issues a
# publicly-trusted cert for `client_cert_dns_names` (via `client_cert_issuer`,
# DNS-01 recommended for raw-TCP hosts) into Secret `stalwart-client-tls`; the
# client proxy terminates TLS with it, so strict clients / OAuth proxies get a
# trusted cert instead of Stalwart's self-signed. Only when both a listen IP and
# SAN names are set.
resource "kubectl_manifest" "stalwart_client_cert" {
  for_each = var.client_listen_ip != "" && length(var.client_cert_dns_names) > 0 ? local.instances : toset([])

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "stalwart-client-tls"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      secretName = "stalwart-client-tls"
      dnsNames   = var.client_cert_dns_names
      issuerRef = {
        name  = var.client_cert_issuer
        kind  = "ClusterIssuer"
        group = "cert-manager.io"
      }
    }
  })
}
