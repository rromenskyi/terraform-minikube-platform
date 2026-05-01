# Auto-discovery for the platform-dash DB panel.
#
# When platform-dash is deployed and the shared Postgres / Redis are
# enabled, provision a read-only `dashboard_ro` user on each, drop
# the URI into a Secret, and emit a single ConfigMap that the
# dashboard's discovery loop picks up. Operator does nothing per-DB —
# enabling/disabling postgres or redis flips the matching targets
# automatically on the next apply.
#
# Mirrors the tenant-provisioner Job pattern from modules/project so
# the security posture (random_password sourced inline into psql /
# redis-cli, idempotent re-run via WHERE-NOT-EXISTS) is the same as
# the per-tenant DB users that already exist.

locals {
  # Dashboard's namespace = whatever the platform-dash module emits
  # (the shared `platform` namespace). Null when disabled — every
  # resource here gates on that.
  dash_namespace   = try(module.platform_dash.namespace, null)
  dash_pg_enabled  = module.postgres.host != null && local.dash_namespace != null
  dash_red_enabled = module.redis.host != null && local.dash_namespace != null

  # The CM `targets.yaml` content. Kept here as a list of plain maps
  # so a future second instance, or external clusters, can append.
  dash_pg_target = local.dash_pg_enabled ? [{
    name    = "platform-pg"
    kind    = "postgres"
    cluster = "local"
    label   = "platform / postgres"
    secret = {
      name      = "platform-pg-dashboard"
      key       = "URI"
      namespace = local.dash_namespace
    }
  }] : []

  dash_redis_target = local.dash_red_enabled ? [{
    name    = "platform-redis"
    kind    = "redis"
    cluster = "local"
    label   = "platform / redis"
    secret = {
      name      = "platform-redis-dashboard"
      key       = "URI"
      namespace = local.dash_namespace
    }
  }] : []

  dash_db_targets = concat(local.dash_pg_target, local.dash_redis_target)
}

# ── dashboard_ro passwords ───────────────────────────────────────────────────
# Symbol-free so the URI doesn't need URL-encoding (the dashboard
# pg / ioredis clients consume raw connection strings).
resource "random_password" "dashboard_ro_pg" {
  count   = local.dash_pg_enabled ? 1 : 0
  length  = 32
  special = false
}

resource "random_password" "dashboard_ro_redis" {
  count   = local.dash_red_enabled ? 1 : 0
  length  = 32
  special = false
}

# ── Postgres: provision dashboard_ro via psql Job ────────────────────────────
# pg_monitor grant covers every pg_stat_* read the dashboard makes;
# CONNECT to the system `postgres` db is the only data-path access we
# need (all stat queries can run against any single db on a
# pg_monitor connection).
resource "kubernetes_job_v1" "pg_dashboard_ro_setup" {
  count      = local.dash_pg_enabled ? 1 : 0
  depends_on = [module.postgres]

  metadata {
    name      = "pg-dashboard-ro-setup"
    namespace = module.postgres.namespace
    labels = {
      "managed-by" = "platform-dash-db-discovery"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "pg-dashboard-ro-setup"
        }
      }
      spec {
        restart_policy = "Never"

        container {
          name  = "pg-dashboard-ro-setup"
          image = "postgres:16-alpine"

          env_from {
            secret_ref {
              name = module.postgres.superuser_secret_name
            }
          }
          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }
          env {
            name  = "RO_PASSWORD"
            value = random_password.dashboard_ro_pg[0].result
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }

          # Idempotent: WHERE-NOT-EXISTS dance for CREATE ROLE; ALTER
          # always re-syncs the password so terraform's state stays
          # the source of truth (rotation = re-apply).
          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${module.postgres.host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = 'dashboard_ro'\" | grep -q 1 || psql -h ${module.postgres.host} -U postgres -c \"CREATE ROLE dashboard_ro WITH LOGIN PASSWORD '$RO_PASSWORD'\"",
              "psql -h ${module.postgres.host} -U postgres -c \"ALTER ROLE dashboard_ro WITH PASSWORD '$RO_PASSWORD'\"",
              "psql -h ${module.postgres.host} -U postgres -c \"GRANT pg_monitor TO dashboard_ro\"",
              "psql -h ${module.postgres.host} -U postgres -c \"GRANT CONNECT ON DATABASE postgres TO dashboard_ro\""
            ])
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts { create = "2m" }
}

# ── Redis: provision dashboard_ro via redis-cli ACL Job ──────────────────────
# +@read +info covers the INFO command and any future read query;
# `~*` allows access to all keys (read-only); `&*` allows all
# pub/sub channels (subscribe is read in spirit). No write categories.
resource "kubernetes_job_v1" "redis_dashboard_ro_setup" {
  count      = local.dash_red_enabled ? 1 : 0
  depends_on = [module.redis]

  metadata {
    name      = "redis-dashboard-ro-setup"
    namespace = module.redis.namespace
    labels = {
      "managed-by" = "platform-dash-db-discovery"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "redis-dashboard-ro-setup"
        }
      }
      spec {
        restart_policy = "Never"

        container {
          name  = "redis-dashboard-ro-setup"
          image = "redis:7-alpine"

          env_from {
            secret_ref {
              name = module.redis.default_secret_name
            }
          }
          env {
            name  = "RO_PASSWORD"
            value = random_password.dashboard_ro_redis[0].result
          }

          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          # ACL SETUSER is idempotent — re-applying is a no-op when
          # the user already matches. -a uses the `default` (root)
          # password from the env_from Secret.
          command = [
            "sh", "-c",
            "redis-cli -h ${module.redis.host} -a \"$REDIS_PASSWORD\" --no-auth-warning ACL SETUSER dashboard_ro on \">$RO_PASSWORD\" \"~*\" \"&*\" +@read +info"
          ]
        }
      }
    }
  }

  wait_for_completion = true
  timeouts { create = "2m" }
}

# ── Per-DB cred Secrets in dashboard's namespace ─────────────────────────────
# Lives in the dashboard's ns so the dashboard SA's existing
# secrets-read RBAC (cluster-wide via the wildcard rule) covers it
# without per-namespace RoleBindings. Rotating the password = next
# terraform apply rebuilds both the user and this Secret atomically.
resource "kubernetes_secret_v1" "platform_pg_dashboard" {
  count      = local.dash_pg_enabled ? 1 : 0
  depends_on = [kubernetes_job_v1.pg_dashboard_ro_setup]

  metadata {
    name      = "platform-pg-dashboard"
    namespace = local.dash_namespace
    labels = {
      "managed-by" = "platform-dash-db-discovery"
    }
  }
  data = {
    URI = "postgres://dashboard_ro:${random_password.dashboard_ro_pg[0].result}@${module.postgres.host}:${module.postgres.port}/postgres?sslmode=disable"
  }
}

resource "kubernetes_secret_v1" "platform_redis_dashboard" {
  count      = local.dash_red_enabled ? 1 : 0
  depends_on = [kubernetes_job_v1.redis_dashboard_ro_setup]

  metadata {
    name      = "platform-redis-dashboard"
    namespace = local.dash_namespace
    labels = {
      "managed-by" = "platform-dash-db-discovery"
    }
  }
  data = {
    URI = "redis://dashboard_ro:${random_password.dashboard_ro_redis[0].result}@${module.redis.host}:${module.redis.port}/0"
  }
}

# ── Discovery ConfigMap ──────────────────────────────────────────────────────
# Single source of truth the dashboard's lib/db-targets.server.ts
# reads via its SA. `targets.yaml` is the documented schema.
resource "kubernetes_config_map_v1" "platform_dash_db_targets" {
  count = local.dash_namespace != null && length(local.dash_db_targets) > 0 ? 1 : 0

  metadata {
    name      = "platform-dash-db-targets"
    namespace = local.dash_namespace
    labels = {
      "managed-by" = "platform-dash-db-discovery"
    }
  }

  data = {
    "targets.yaml" = yamlencode(local.dash_db_targets)
  }
}

output "platform_dash_db_targets" {
  value       = local.dash_db_targets
  description = "Auto-generated DB targets fed into the platform-dash discovery CM."
}
