variable "name" {
  description = "Component name — used as Deployment/Service name and label selector"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into"
  type        = string
}

variable "image" {
  description = "Container image (e.g. nginx:alpine)"
  type        = string
}

variable "port" {
  description = "Container port exposed by the application"
  type        = number
}

variable "replicas" {
  description = "Desired number of pod replicas"
  default     = 2
}

variable "resources" {
  description = "CPU/memory requests and limits"
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
  description = "HTTP path used for liveness and readiness probes"
  default     = "/"
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
