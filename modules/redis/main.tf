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
  description = "Deploy the Redis StatefulSet. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the Redis StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PersistentVolume for Redis AOF data. Redis lands at <volume_base_path>/<namespace>/redis/. Must resolve to a real writable directory from the kubelet's point of view."
  type        = string
  default     = "/data/vol"
}

variable "memory_request" {
  description = "Memory request for the Redis pod. Redis mmaps its dataset, so this should comfortably cover the working set — anything less than 256Mi is cramped for AOF rewrites."
  type        = string
  default     = "256Mi"
}

variable "memory_limit" {
  description = "Memory limit for the Redis pod. Hitting this cap kills the pod and takes all tenants down — bump if you expect many large values."
  type        = string
  default     = "1Gi"
}

variable "node_selector" {
  description = "Node-selector labels the Redis pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`)."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the Redis pod tolerates. Empty list = pod cannot land on any tainted node."
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

# ── Default (root) password ───────────────────────────────────────────────────

resource "random_password" "default" {
  for_each = local.instances

  length  = 32
  special = false
}

# `requirepass` targets the built-in `default` user on Redis 6+. Per-tenant
# ACL users are provisioned in the consuming project module (one user per
# namespace with its own key prefix); the secret below is platform-root
# credentials only — tenants don't see it.
resource "kubernetes_secret_v1" "default" {
  for_each = local.instances

  metadata {
    name      = "redis-default"
    namespace = var.namespace
  }

  data = {
    REDIS_PASSWORD = random_password.default["enabled"].result
  }
}

# ── Persistent storage (AOF) ──────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "redis" {
  for_each = local.instances

  metadata {
    name = "platform-redis-data"
  }

  spec {
    capacity = {
      storage = "5Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.volume_base_path}/${var.namespace}/redis"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "redis" {
  for_each = local.instances

  metadata {
    name      = "redis-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.redis["enabled"].metadata[0].name

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "redis" {
  for_each = local.instances

  metadata {
    name      = "redis"
    namespace = var.namespace
    labels    = { app = "redis" }
  }

  spec {
    replicas     = 1
    service_name = "redis"

    selector {
      match_labels = { app = "redis" }
    }

    template {
      metadata {
        labels = { app = "redis" }
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

        # hostPath under /data/vol/<ns>/redis is root-owned. Redis runs as
        # UID 999 in the official image — without this init, the server
        # crashes on start with "Can't chdir to '/data': Permission denied".
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

          command = ["sh", "-c", "chown -R 999:999 /data"]

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        # Seed /data/users.acl on first boot with the built-in `default`
        # user. We swap `--requirepass` for `--aclfile` below so ACL
        # entries created by tenant setup Jobs (via `ACL SAVE`) survive
        # pod restarts — without a file, ACLs live only in memory and
        # every bounce wipes every tenant's Redis login, which is the
        # exact regression we're fixing here. `-s` means "only seed if
        # the file is missing or empty", so a restart with an already-
        # populated users.acl never touches it.
        init_container {
          name  = "seed-users-acl"
          image = "redis:7-alpine"

          # Root because chown-data re-owns /data to 999 *after* this
          # container would run if order were swapped; running as root
          # sidesteps any fs_group race on the first boot.
          security_context {
            run_as_user = 0
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "50m", memory = "32Mi" }
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.default["enabled"].metadata[0].name
            }
          }

          # `>password` is ACL-syntax (add this plaintext password,
          # Redis hashes it on load). `~*` = all keys, `&*` = all pub/sub
          # channels, `+@all` = all commands — the full "superuser"
          # profile `default` had under `--requirepass`.
          command = ["sh", "-c", "test -s /data/users.acl || printf 'user default on >%s ~* &* +@all\\n' \"$REDIS_PASSWORD\" > /data/users.acl && chown 999:999 /data/users.acl"]

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }

        security_context {
          run_as_user = 999
          fs_group    = 999
        }

        container {
          name  = "redis"
          image = "redis:7-alpine"

          port {
            container_port = 6379
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.default["enabled"].metadata[0].name
            }
          }

          # `--aclfile` lets Redis persist every `ACL SETUSER ... ; ACL
          # SAVE` pair to disk, so tenant users survive pod restarts.
          # `requirepass` and `aclfile` are mutually exclusive (Redis
          # refuses to start with both set) — the `default` user's
          # password instead comes from users.acl, which the
          # seed-users-acl initContainer populates on first boot from
          # the same $REDIS_PASSWORD env. `appendonly yes` is orthogonal
          # (AOF persists keyspace writes); `appendfsync everysec` is
          # the usual good-enough durability/throughput compromise.
          args = [
            "--aclfile", "/data/users.acl",
            "--appendonly", "yes",
            "--appendfsync", "everysec",
            "--dir", "/data",
          ]

          resources {
            requests = {
              cpu    = "50m"
              memory = var.memory_request
            }
            limits = {
              cpu    = "500m"
              memory = var.memory_limit
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          startup_probe {
            exec {
              command = ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep -q PONG"]
            }
            period_seconds    = 5
            failure_threshold = 30
            timeout_seconds   = 3
          }

          liveness_probe {
            exec {
              command = ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep -q PONG"]
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 3
          }

          readiness_probe {
            exec {
              command = ["sh", "-c", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep -q PONG"]
            }
            period_seconds    = 5
            failure_threshold = 3
            timeout_seconds   = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.redis["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "redis" {
  for_each = local.instances

  metadata {
    name      = "redis"
    namespace = var.namespace
    labels    = { app = "redis" }
  }

  spec {
    selector = { app = "redis" }

    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Redis is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.redis : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "Redis in-cluster hostname, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.redis : s.metadata[0].name])
  description = "Redis Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.redis : s.spec[0].port[0].port])
  description = "Redis Service port, or null if disabled."
}

output "default_password" {
  value       = one([for p in random_password.default : p.result])
  sensitive   = true
  description = "Password for the built-in `default` Redis user (aka root). Tenants don't get this — each project module provisions its own ACL user. Null if disabled."
}

output "default_secret_name" {
  value       = one([for s in kubernetes_secret_v1.default : s.metadata[0].name])
  description = "Name of the Secret holding the `default`-user password. The tenant-provisioner Job reads it when calling ACL SETUSER. Null if disabled."
}
