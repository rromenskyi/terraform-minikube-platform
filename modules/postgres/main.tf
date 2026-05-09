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

          # Override the image's default `CMD ["postgres"]` to inject
          # `shared_preload_libraries=pg_stat_statements`. The
          # extension's stats-collection hooks have to load at server
          # start, not via `CREATE EXTENSION` (which only registers
          # the SQL view). Without this, the view exists but every
          # `pg_stat_statements` row is empty. `track=all` includes
          # statements inside functions/procedures, useful for the
          # platform-dash slow-queries panel.
          args = [
            "postgres",
            "-c", "shared_preload_libraries=pg_stat_statements",
            "-c", "pg_stat_statements.track=all",
          ]

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

# pg_stat_statements extension creator. The shared_preload_libraries
# load (in the StatefulSet container `args` above) is necessary but
# not sufficient — Postgres also needs `CREATE EXTENSION` to register
# the SQL view per database. Run it against the default `postgres`
# database so the platform-dash slow-queries panel finds the view
# when it connects to this instance. Tenant databases get their own
# `CREATE EXTENSION` from the per-tenant provisioner Job in
# modules/project (separate change once that path lands).
#
# The Job uses `for_each = local.instances` to disappear cleanly when
# `var.enabled = false`, mirrors the rest of the module. The pod
# image is `postgres:16-alpine` so `psql` is in PATH; password comes
# from the same superuser Secret the StatefulSet's `env_from` uses.
# `IF NOT EXISTS` keeps the Job idempotent across restarts; there's
# no spec change after the first successful apply unless the extension
# list itself changes.
resource "kubernetes_job_v1" "pg_extensions" {
  for_each = local.instances

  metadata {
    name      = "postgres-pg-extensions"
    namespace = var.namespace
    labels    = { app = "postgres" }
  }

  spec {
    backoff_limit              = 6
    ttl_seconds_after_finished = 300

    template {
      metadata {
        labels = { app = "postgres", job = "pg-extensions" }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "psql"
          image = "postgres:16-alpine"

          # `psql` reads `PGPASSWORD`, not `POSTGRES_PASSWORD` (which is
          # what the Postgres image's docker-entrypoint.sh consumes).
          # Pull the same Secret value out into the right env name.
          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.superuser["enabled"].metadata[0].name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          env {
            name  = "PGHOST"
            value = "postgres.${var.namespace}.svc.cluster.local"
          }
          env {
            name  = "PGUSER"
            value = "postgres"
          }
          env {
            name  = "PGDATABASE"
            value = "postgres"
          }

          command = ["sh", "-c"]
          args = [
            "until pg_isready -h \"$PGHOST\" -U \"$PGUSER\"; do sleep 2; done; psql -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'",
          ]

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }
      }
    }

  }

  wait_for_completion = true
  timeouts {
    create = "3m"
    update = "3m"
  }

  depends_on = [kubernetes_stateful_set_v1.postgres]
}

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

