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

variable "enabled" {
  description = "Deploy the MySQL StatefulSet. When `false`, no resources are created and every output collapses to null — a disabled MySQL cleanly cascades into `modules/project` (components with `db: true` fail a precondition instead of silently deploying a broken StatefulSet)."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the MySQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it so the sibling Postgres/Redis/Ollama modules can share the same namespace without piggybacking on this module. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for MySQL data. MySQL lands at <volume_base_path>/<namespace>/mysql/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol)."
  type        = string
  default     = "/data/vol"
}

variable "node_selector" {
  description = "Node-selector labels the MySQL pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the MySQL pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

locals {
  # Singleton-ish toggle. All resources below use `for_each =
  # local.instances` — yields one instance keyed "enabled" when the
  # module is on, and an empty set when off. Pattern matches the
  # sibling terraform-k8s-addons module so `terraform state list`
  # looks uniform across the platform stack.
  instances = var.enabled ? toset(["enabled"]) : toset([])
}

# ── Root password ─────────────────────────────────────────────────────────────

resource "random_password" "root" {
  for_each = local.instances

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "mysql_root" {
  for_each = local.instances

  metadata {
    name      = "mysql-root"
    namespace = var.namespace
  }

  data = {
    MYSQL_ROOT_PASSWORD = random_password.root["enabled"].result
  }
}

# ── Persistent storage ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "mysql" {
  for_each = local.instances

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
        path = "${var.volume_base_path}/${var.namespace}/mysql"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "mysql" {
  for_each = local.instances

  metadata {
    name      = "mysql-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.mysql["enabled"].metadata[0].name

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "mysql" {
  for_each = local.instances

  metadata {
    name      = "mysql"
    namespace = var.namespace
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
        # Pod placement primitives — empty defaults preserve prior
        # scheduler behaviour.
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
          name  = "mysql"
          image = "mysql:8.0"

          port {
            container_port = 3306
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.mysql_root["enabled"].metadata[0].name
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
            claim_name = kubernetes_persistent_volume_claim_v1.mysql["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Services ──────────────────────────────────────────────────────────────────

# In-cluster access (pods → mysql.platform.svc.cluster.local:3306)
resource "kubernetes_service_v1" "mysql" {
  for_each = local.instances

  metadata {
    name      = "mysql"
    namespace = var.namespace
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
#
# All outputs collapse to `null` when the module is disabled. Downstream
# consumers (modules/project) pass these through to tenant-side
# precondition checks, so a disabled MySQL produces a clear error the
# first time a component asks for it instead of a silent mis-deploy.

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where MySQL is deployed, or null if the module is disabled."
}

output "host" {
  value = one([
    for s in kubernetes_service_v1.mysql :
    "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"
  ])
  description = "MySQL in-cluster hostname, or null if the module is disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.mysql : s.metadata[0].name])
  description = "MySQL Service name, or null if the module is disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.mysql : s.spec[0].port[0].port])
  description = "MySQL Service port, or null if the module is disabled."
}

output "root_password" {
  value       = one([for p in random_password.root : p.result])
  sensitive   = true
  description = "MySQL root password (also in the mysql-root Secret), or null if the module is disabled."
}
