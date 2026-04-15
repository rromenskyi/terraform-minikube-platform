variable "name" {}
variable "namespace" {}
variable "image" {}
variable "port" {}
variable "replicas" {
  default = 2
}
variable "resources" {
  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "500m"
      memory = "512Mi"
    }
  }
}
variable "health_path" {
  default = "/"
}
variable "domain" {
  default = null
}
variable "ingress_enabled" {
  default = true
}

resource "kubernetes_deployment" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      app = var.name
    }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        app = var.name
      }
    }

    template {
      metadata {
        labels = {
          app = var.name
        }
      }

      spec {
        container {
          name  = var.name
          image = var.image

          port {
            container_port = var.port
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          liveness_probe {
            http_get {
              path = var.health_path
              port = var.port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = var.health_path
              port = var.port
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      app = var.name
    }
  }

  spec {
    selector = {
      app = var.name
    }

    port {
      port        = var.port
      target_port = var.port
    }
  }
}

resource "kubernetes_manifest" "ingressroute" {
  count = var.ingress_enabled && var.domain != null ? 1 : 0

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = var.name
      namespace = var.namespace
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`${var.domain}`)"
        kind  = "Rule"
        services = [{
          name = var.name
          port = var.port
        }]
      }]
      tls = {
        certResolver = "letsencrypt-production"
      }
    }
  }
}
