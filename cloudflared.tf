# Cloudflare Tunnel connector (cloudflared)
# Runs in the ops namespace and connects to the tunnel created in cloudflare.tf.
# Config is managed from the Cloudflare dashboard (config_src = "cloudflare").

# v5 dropped the `tunnel_token` attribute on the tunnel resource and
# split it into a dedicated data source. The token is regenerated each
# time it's read (Cloudflare's behaviour, not Terraform's), but
# refreshing the data source on every plan keeps the Secret in lockstep
# with whatever Cloudflare currently considers valid.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "main" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

resource "kubernetes_secret_v1" "cloudflared_token" {
  depends_on = [module.k8s]

  metadata {
    name      = "cloudflared-token"
    namespace = "ops"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "cloudflared"
    }
  }

  data = {
    token = data.cloudflare_zero_trust_tunnel_cloudflared_token.main.token
  }

  type = "Opaque"
}

resource "kubernetes_deployment_v1" "cloudflared" {
  depends_on = [module.k8s, cloudflare_zero_trust_tunnel_cloudflared.main]

  metadata {
    name      = "cloudflared"
    namespace = "ops"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "cloudflared"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = { app = "cloudflared" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 1
        max_surge       = 1
      }
    }

    template {
      metadata {
        labels = { app = "cloudflared" }
      }

      spec {
        container {
          name  = "cloudflared"
          image = "cloudflare/cloudflared:2025.1.0"

          command = [
            "cloudflared",
            "tunnel",
            "--no-autoupdate",
            "run",
            "--token",
            "$(TUNNEL_TOKEN)",
          ]

          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.cloudflared_token.metadata[0].name
                key  = "token"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/ready"
              port = 20241
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = 20241
            }
            initial_delay_seconds = 10
            period_seconds        = 5
            failure_threshold     = 3
          }
        }

        termination_grace_period_seconds = 30

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                label_selector {
                  match_labels = { app = "cloudflared" }
                }
                topology_key = "kubernetes.io/hostname"
              }
            }
          }
        }
      }
    }
  }
}
