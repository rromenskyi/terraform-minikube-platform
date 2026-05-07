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
    helm = {
      source  = "hashicorp/helm"
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

variable "storage_class" {
  description = "StorageClass name for the Redis PVC. Empty (default) = no `storageClassName` field is set on the PVC, so the cluster's default StorageClass is used (typically `local-path` on k3s, hostPath-backed and node-pinned). Set to a HA-capable SC (e.g. one of `services.longhorn.tag_pools`'s `longhorn-<pool>` outputs) to opt the Redis volume into distributed block storage that survives node failure. The choice is operator-side per `services.redis.storage_class` in `config/platform.yaml` — engine stays generic and does not assume Longhorn or any particular SC implementation is present."
  type        = string
  default     = ""
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

variable "sentinel" {
  description = "Optional Valkey Sentinel HA topology. When `enabled = true`, the module switches from the default single-StatefulSet implementation to a Bitnami `valkey` Helm release running `architecture: replication` + `sentinel.enabled: true`, plus an HAProxy Deployment in front (sentinel-aware health checks via `tcp-check expect role:master`) so consumers keep talking to the flat `redis.<ns>.svc:6379` Service without any client-side changes. **Operator opts in** via `services.redis.sentinel:` in `config/platform.yaml`. Default `enabled = false` preserves the simple single-instance path. Switching `false → true` is a one-way data wipe (the existing single-instance PVC is destroyed when its for_each collapses; tenant ACL Jobs need re-trigger to repopulate per-tenant users on the fresh chart deploy)."
  type = object({
    enabled             = optional(bool, false)
    replica_count       = optional(number, 3)
    quorum              = optional(number, 2)
    chart_version       = optional(string, "5.6.1")
    image_repo          = optional(string, "bitnami/valkey")
    image_tag           = optional(string, "latest")
    sentinel_image_repo = optional(string, "bitnami/valkey-sentinel")
    sentinel_image_tag  = optional(string, "latest")
    haproxy_image       = optional(string, "haproxytech/haproxy-alpine:3.0")
    haproxy_replicas    = optional(number, 2)
  })
  default = {}
}

locals {
  instances          = var.enabled ? toset(["enabled"]) : toset([])
  single_instances   = (var.enabled && !var.sentinel.enabled) ? toset(["enabled"]) : toset([])
  sentinel_instances = (var.enabled && var.sentinel.enabled) ? toset(["enabled"]) : toset([])
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

# ── Persistent storage (AOF + RDB) ────────────────────────────────────────────
#
# Dynamic-provisioned PVC. The chosen StorageClass is operator-supplied
# via `var.storage_class`:
#   - Empty (default) → no `storageClassName` is set, cluster default
#     SC is used (typically `local-path` on k3s — hostPath-backed and
#     node-pinned, no HA but zero extra dependencies).
#   - Non-empty → the named SC handles provisioning. A common opt-in
#     is to point this at a `longhorn-<pool>` SC emitted by
#     `services.longhorn.tag_pools` (operator-defined topology pools)
#     — Longhorn replicates blocks across the pool's tagged nodes, so
#     node-loss events re-attach the logical PV to a surviving node
#     and Valkey resumes from the last AOF/RDB sync. The redis module
#     itself stays storage-implementation-agnostic — it does not
#     reference Longhorn (or any other CSI driver) directly.

resource "kubernetes_persistent_volume_claim_v1" "redis" {
  for_each = local.single_instances

  metadata {
    name      = "redis-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class != "" ? var.storage_class : null

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "redis" {
  for_each = local.single_instances

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
          image = "valkey/valkey:9-alpine"

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
          image = "valkey/valkey:9-alpine"

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

# ── Sentinel mode (opt-in via var.sentinel.enabled) ──────────────────────────
#
# Bitnami `valkey` Helm chart in `architecture: replication` +
# `sentinel.enabled: true` mode deploys a single StatefulSet of N
# valkey pods (1 elected primary + N-1 replicas via Sentinel
# orchestration). Each pod runs a Sentinel sidecar; quorum is set
# by `var.sentinel.quorum` (default 2 for a 3-node deployment).
#
# Bitnami's chart explicitly does NOT include an HAProxy proxy in
# sentinel mode — clients are expected to be Sentinel-aware. To
# preserve transparent client compatibility (consumers keep talking
# to the flat `redis.<ns>.svc:6379` Service), we run our own HAProxy
# Deployment in front. HAProxy uses TCP-check + `tcp-check expect
# string role:master` to filter — only pods replying with
# `role:master` to the `INFO replication` query pass health checks,
# so HAProxy routes traffic exclusively to whichever pod is the
# current primary. On Sentinel-driven failover the new primary
# starts replying `role:master`, the old one drops out of the
# health-check pool, traffic flips within HAProxy's check interval
# (1s default).
#
# The chart's auth.password is wired to the same `redis-default`
# Secret single mode uses, so consumers see one password across
# both modes. ACL changes (per-tenant SETUSER from project module
# Jobs) propagate from primary → replicas via Redis 6+ replication
# automatically.

resource "helm_release" "valkey_sentinel" {
  for_each = local.sentinel_instances

  name       = "redis"
  repository = "https://charts.bitnami.com/bitnami"
  chart      = "valkey"
  version    = var.sentinel.chart_version
  namespace  = var.namespace
  timeout    = 900

  values = [yamlencode({
    architecture = "replication"

    image = {
      registry   = "docker.io"
      repository = var.sentinel.image_repo
      tag        = var.sentinel.image_tag
    }

    sentinel = {
      enabled = true
      quorum  = var.sentinel.quorum
      image = {
        registry   = "docker.io"
        repository = var.sentinel.sentinel_image_repo
        tag        = var.sentinel.sentinel_image_tag
      }
      # Bitnami chart's default sentinel resource preset is tight
      # (~150m CPU limit). Sentinel needs timer interrupts firing
      # 10/sec consistently — at 150m CFS throttling delays them
      # past the 2s threshold and Sentinel enters TILT mode (local
      # PING blocks 60s+, probes time out, daemon useless).
      # Lift to 500m so timer-driven discovery + election keep up.
      resourcesPreset = "none"
      resources = {
        requests = { cpu = "100m", memory = "64Mi" }
        limits   = { cpu = "500m", memory = "128Mi" }
      }
    }

    auth = {
      enabled                   = true
      existingSecret            = "redis-default"
      existingSecretPasswordKey = "REDIS_PASSWORD"
    }

    primary = {
      persistence = {
        enabled      = var.storage_class != ""
        storageClass = var.storage_class
        size         = "5Gi"
      }
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }

    replica = {
      replicaCount = var.sentinel.replica_count - 1
      persistence = {
        enabled      = var.storage_class != ""
        storageClass = var.storage_class
        size         = "5Gi"
      }
      nodeSelector = var.node_selector
      tolerations  = var.tolerations
    }
  })]
}

# HAProxy frontend so consumers keep using flat `redis:6379`.
# Health check filters to current primary via `role:master` reply.

resource "kubernetes_config_map_v1" "haproxy_config" {
  for_each = local.sentinel_instances

  metadata {
    name      = "redis-haproxy-config"
    namespace = var.namespace
  }

  data = {
    "haproxy.cfg" = <<-EOT
      global
        log stdout format raw local0 info
        maxconn 4096

      defaults
        log global
        mode tcp
        option tcplog
        timeout connect 5s
        timeout client  60s
        timeout server  60s

      resolvers k8s
        parse-resolv-conf
        accepted_payload_size 8192
        hold valid 10s

      frontend redis_front
        bind *:6379
        default_backend redis_back

      backend redis_back
        option tcp-check
        tcp-check connect
        tcp-check send AUTH\ ${random_password.default["enabled"].result}\r\n
        tcp-check expect string +OK
        tcp-check send PING\r\n
        tcp-check expect string +PONG
        tcp-check send info\ replication\r\n
        tcp-check expect string role:master
        tcp-check send QUIT\r\n
        tcp-check expect string +OK
        server-template valkey ${var.sentinel.replica_count} redis-valkey-headless.${var.namespace}.svc.cluster.local:6379 check inter 1s rise 1 fall 2 resolvers k8s init-addr none
    EOT
  }
}

resource "kubernetes_deployment_v1" "haproxy" {
  for_each = local.sentinel_instances

  depends_on = [helm_release.valkey_sentinel]

  metadata {
    name      = "redis-haproxy"
    namespace = var.namespace
    labels    = { app = "redis", component = "haproxy" }
  }

  spec {
    replicas = var.sentinel.haproxy_replicas

    selector {
      match_labels = { app = "redis", component = "haproxy" }
    }

    template {
      metadata {
        labels = { app = "redis", component = "haproxy" }
      }

      spec {
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

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = { app = "redis", component = "haproxy" }
                }
              }
            }
          }
        }

        container {
          name  = "haproxy"
          image = var.sentinel.haproxy_image

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = "redis-default"
                key  = "REDIS_PASSWORD"
              }
            }
          }

          port {
            name           = "redis"
            container_port = 6379
          }

          volume_mount {
            name       = "config"
            mount_path = "/usr/local/etc/haproxy"
          }

          # HAProxy expands $REDIS_PASSWORD via the env var at startup
          # (haproxy 2.4+ supports environment variable substitution
          # in its config — `${REDIS_PASSWORD}` literal sits in the
          # ConfigMap and HAProxy fills it from the env at parse time).
          args = ["-f", "/usr/local/etc/haproxy/haproxy.cfg"]

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          readiness_probe {
            tcp_socket { port = 6379 }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            tcp_socket { port = 6379 }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.haproxy_config["enabled"].metadata[0].name
          }
        }
      }
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
