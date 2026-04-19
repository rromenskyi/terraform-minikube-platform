terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

variable "namespace_prefix" {
  description = "Optional prefix for the platform namespace"
  type        = string
  default     = ""
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for MySQL data. MySQL lands at <volume_base_path>/<namespace_prefix>platform/mysql/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol)."
  type        = string
  default     = "/data/vol"
}

# ── Namespace ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = "${var.namespace_prefix}platform"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# ── Root password ─────────────────────────────────────────────────────────────

resource "random_password" "root" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "mysql_root" {
  metadata {
    name      = "mysql-root"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  data = {
    MYSQL_ROOT_PASSWORD = random_password.root.result
  }
}

# ── Persistent storage ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "mysql" {
  metadata {
    name = "platform-mysql-data"
  }

  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.volume_base_path}/${kubernetes_namespace_v1.platform.metadata[0].name}/mysql"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mysql" {
  metadata {
    name      = "mysql-data"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.mysql.metadata[0].name

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = { app = "mysql" }
  }

  spec {
    replicas     = 1
    service_name = "mysql"

    selector {
      match_labels = { app = "mysql" }
    }

    template {
      metadata {
        labels = { app = "mysql" }
      }

      spec {
        container {
          name  = "mysql"
          image = "mysql:8.0"

          port {
            container_port = 3306
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mysql_root.metadata[0].name
            }
          }

          env {
            name  = "MYSQL_ROOT_HOST"
            value = "%"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
          }

          # Startup probe: MySQL 8.0 first init can take 60-90s.
          # Gives up to 5m (30 × 10s) before declaring the container broken.
          startup_probe {
            exec {
              command = ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$MYSQL_ROOT_PASSWORD\""]
            }
            period_seconds    = 10
            failure_threshold = 30
            timeout_seconds   = 5
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$MYSQL_ROOT_PASSWORD\""]
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 5
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "mysql -h 127.0.0.1 -uroot -p\"$MYSQL_ROOT_PASSWORD\" -e 'SELECT 1'"]
            }
            period_seconds    = 5
            failure_threshold = 3
            timeout_seconds   = 5
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.mysql.metadata[0].name
          }
        }
      }
    }
  }
}

# ── Services ──────────────────────────────────────────────────────────────────

# In-cluster access (pods → mysql.platform.svc.cluster.local:3306)
resource "kubernetes_service_v1" "mysql" {
  metadata {
    name      = "mysql"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = { app = "mysql" }
  }

  spec {
    selector = { app = "mysql" }

    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "namespace" {
  value       = kubernetes_namespace_v1.platform.metadata[0].name
  description = "Namespace where MySQL is deployed"
}

output "host" {
  value       = "${kubernetes_service_v1.mysql.metadata[0].name}.${kubernetes_namespace_v1.platform.metadata[0].name}.svc.cluster.local"
  description = "MySQL in-cluster hostname"
}

output "service_name" {
  value       = kubernetes_service_v1.mysql.metadata[0].name
  description = "MySQL Service name"
}

output "port" {
  value       = kubernetes_service_v1.mysql.spec[0].port[0].port
  description = "MySQL Service port"
}

output "root_secret_name" {
  value       = kubernetes_secret_v1.mysql_root.metadata[0].name
  description = "Name of the Secret containing MYSQL_ROOT_PASSWORD"
}

output "root_password" {
  value       = random_password.root.result
  sensitive   = true
  description = "MySQL root password (also in the mysql-root Secret)"
}
