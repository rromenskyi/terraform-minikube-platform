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
  description = "Deploy the PostgreSQL StatefulSet. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the PostgreSQL StatefulSet lives in. Expected to exist already — the root-level `kubernetes_namespace_v1.platform` resource owns it. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for PostgreSQL data. Lands at <volume_base_path>/<namespace>/postgres/."
  type        = string
  default     = "/data/vol"
}

variable "node_selector" {
  description = "Node-selector labels the Postgres pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the Postgres pod tolerates. Empty list = pod cannot land on any tainted node."
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
  instances = var.enabled ? toset(["enabled"]) : toset([])
}

# ── Superuser password ────────────────────────────────────────────────────────

resource "random_password" "superuser" {
  for_each = local.instances

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "superuser" {
  for_each = local.instances

  metadata {
    name      = "postgres-superuser"
    namespace = var.namespace
  }

  # `postgres:` image entrypoint reads `POSTGRES_PASSWORD` for the
  # `postgres` superuser on first init. The tenant-provisioner Job pulls
  # the same secret via env_from when it opens a `psql` connection.
  data = {
    POSTGRES_PASSWORD = random_password.superuser["enabled"].result
  }
}

# ── Persistent storage ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "postgres" {
  for_each = local.instances

  metadata {
    name = "platform-postgres-data"
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
        path = "${var.volume_base_path}/${var.namespace}/postgres"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "postgres" {
  for_each = local.instances

  metadata {
    name      = "postgres-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.postgres["enabled"].metadata[0].name

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "postgres" {
  for_each = local.instances

  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }

  spec {
    replicas     = 1
    service_name = "postgres"

    selector {
      match_labels = { app = "postgres" }
    }

    template {
      metadata {
        labels = { app = "postgres" }
      }

      spec {
        # Pod placement primitives — empty defaults preserve prior
        # scheduler behaviour. Pin via `var.node_selector` and tolerate
        # taints via `var.tolerations`.
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

        # The `postgres:` image initdb refuses to run if the mount root
        # itself is not empty — on hostPath that's the kubelet-managed
        # `lost+found` on some filesystems. Pin `PGDATA` to a child
        # subdirectory and make initdb use that fresh folder on first
        # boot. `chown-data` prepares the subdir with the right uid so
        # the init container isn't needed once postgres runs with
        # `USER postgres` (uid 999).
        init_container {
          name  = "chown-data"
          image = "busybox:stable-musl"

          security_context {
            run_as_user = 0
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "50m", memory = "32Mi" }
          }

          command = ["sh", "-c", "mkdir -p /var/lib/postgresql/data/pgdata && chown -R 999:999 /var/lib/postgresql/data"]

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }

        security_context {
          run_as_user = 999
          fs_group    = 999
        }

        container {
          name  = "postgres"
          image = "postgres:16-alpine"

          port {
            container_port = 5432
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.superuser["enabled"].metadata[0].name
            }
          }

          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
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
            mount_path = "/var/lib/postgresql/data"
          }

          startup_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U postgres -h 127.0.0.1"]
            }
            period_seconds    = 5
            failure_threshold = 30
            timeout_seconds   = 5
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U postgres -h 127.0.0.1"]
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 5
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "pg_isready -U postgres -h 127.0.0.1"]
            }
            period_seconds    = 5
            failure_threshold = 3
            timeout_seconds   = 5
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.postgres["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "postgres" {
  for_each = local.instances

  metadata {
    name      = "postgres"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }

  spec {
    selector = { app = "postgres" }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where PostgreSQL is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.postgres : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "PostgreSQL in-cluster hostname, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.postgres : s.metadata[0].name])
  description = "PostgreSQL Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.postgres : s.spec[0].port[0].port])
  description = "PostgreSQL Service port, or null if disabled."
}

output "superuser_password" {
  value       = one([for p in random_password.superuser : p.result])
  sensitive   = true
  description = "Password for the `postgres` superuser (also in the postgres-superuser Secret). Null if disabled."
}

output "superuser_secret_name" {
  value       = one([for s in kubernetes_secret_v1.superuser : s.metadata[0].name])
  description = "Name of the Secret holding the superuser password. The tenant-provisioner Job reads it when creating per-tenant DBs. Null if disabled."
}
