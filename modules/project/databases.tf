# ── MySQL: DB + User + Secret (only when at least one component needs db) ─────

resource "random_password" "db" {
  for_each = local.needs_db ? toset(["enabled"]) : toset([])
  length   = 24
  special  = false
}

# Provisions the DB and user inside the shared MySQL via a Kubernetes Job.
# The Job runs a mysql client container in-cluster — no dependency on local
# kubectl or shell escaping. Database is intentionally NOT dropped on destroy
# to preserve data.
resource "kubernetes_secret_v1" "mysql_setup_env" {
  for_each = local.needs_db ? toset(["enabled"]) : toset([])

  metadata {
    name      = "db-setup-${local.namespace}"
    namespace = var.mysql_namespace
    labels    = module.project_label.tags
  }

  data = {
    SETUP_PASSWORD = "${values(random_password.db)[0].result}"
  }
}

resource "kubernetes_job_v1" "mysql_setup" {
  for_each = local.needs_db ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "db-setup-${local.namespace}"
    namespace = var.mysql_namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "db-setup-${local.namespace}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "mysql-setup"
          image = "mysql:8.4.11"

          # Password from a Secret, not the command line: Job specs are
          # readable far more widely than Secrets.
          env {
            name = "SETUP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.mysql_setup_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env_from {
            secret_ref {
              name = "mysql-root"
            }
          }

          # Tiny one-shot — runs a few DDL statements and exits. Explicit
          # resources are required because the platform namespace's
          # ResourceQuota rejects pods without `limits` and `requests`.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          command = [
            "sh", "-c",
            join("", [
              "mysql -h ${var.mysql_host} -uroot ",
              "-p\"$MYSQL_ROOT_PASSWORD\" -e \"",
              "CREATE DATABASE IF NOT EXISTS \\`${local.db_name}\\`;",
              "CREATE USER IF NOT EXISTS '${local.db_user}'@'%' ",
              "IDENTIFIED BY '$SETUP_PASSWORD';",
              # Re-assert the password: CREATE ... IF NOT EXISTS leaves an
              # existing user's old one (e.g. after state was regenerated).
              "ALTER USER '${local.db_user}'@'%' IDENTIFIED BY '$SETUP_PASSWORD';",
              "GRANT ALL PRIVILEGES ON \\`${local.db_name}\\`.* TO '${local.db_user}'@'%';",
              "FLUSH PRIVILEGES;\"",
            ])
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "2m"
  }
}

resource "kubernetes_secret_v1" "db_credentials" {
  for_each = local.needs_db ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_job_v1.mysql_setup]

  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    DB_HOST = var.mysql_host
    DB_PORT = "3306"
    DB_NAME = local.db_name
    DB_USER = local.db_user
    DB_PASS = values(random_password.db)[0].result
  }
}

# ── PostgreSQL: per-namespace database + user (only when needed) ──────────────

resource "random_password" "postgres" {
  for_each = local.pg_default_instances

  length  = 24
  special = false
}

# Provisions the DB and user via a Kubernetes Job that runs psql
# in-cluster. Database is NOT dropped on destroy — data preservation
# matches the MySQL behaviour.
resource "kubernetes_secret_v1" "postgres_setup_env" {
  for_each = local.pg_default_instances

  metadata {
    name      = "postgres-setup-${local.namespace}"
    namespace = var.postgres_namespace
    labels    = module.project_label.tags
  }

  data = {
    SETUP_PASSWORD = "${values(random_password.postgres)[0].result}"
  }
}

resource "kubernetes_job_v1" "postgres_setup" {
  for_each = local.pg_default_instances

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "postgres-setup-${local.namespace}"
    namespace = var.postgres_namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "postgres-setup-${local.namespace}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "postgres-setup"
          image = "postgres:18.6-alpine"

          # Password from a Secret, not the command line: Job specs are
          # readable far more widely than Secrets.
          env {
            name = "SETUP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres_setup_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env_from {
            secret_ref {
              name = var.postgres_superuser_secret
            }
          }

          # `PGPASSWORD` → picked up by psql automatically. `POSTGRES_PASSWORD`
          # is the key emitted by the postgres-superuser Secret in the platform
          # module; aliased here so both names resolve to the same value.
          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          # Tiny one-shot — see the mysql-setup container for the reasoning.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          # `CREATE DATABASE` / `CREATE ROLE` are not idempotent in vanilla SQL.
          # The DO-blocks below noop when the role or db already exists so
          # re-applies are safe (tenant DB survives terraform destroy → re-apply).
          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.pg_database}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${local.pg_database}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.pg_user}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${local.pg_user}\\\" WITH LOGIN PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${local.pg_user}\\\" WITH PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${local.pg_database}\\\" TO \\\"${local.pg_user}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${local.pg_database} -c \"GRANT ALL ON SCHEMA public TO \\\"${local.pg_user}\\\"\"",
            ])
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "2m"
  }
}

resource "kubernetes_secret_v1" "postgres_credentials" {
  for_each = local.pg_default_instances

  depends_on = [kubernetes_job_v1.postgres_setup]

  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    PG_HOST      = var.postgres_host
    PG_PORT      = "5432"
    PG_DATABASE  = local.pg_database
    PG_USER      = local.pg_user
    PG_PASSWORD  = values(random_password.postgres)[0].result
    DATABASE_URL = "postgres://${local.pg_user}:${values(random_password.postgres)[0].result}@${var.postgres_host}:5432/${local.pg_database}"
  }
}

# ── PostgreSQL: per-namespace EXTRA databases (multi-DB tenants) ──────────────
#
# Triggered by `shared_services.postgres.extra_databases: [<key>, ...]`
# in the domain yaml. Each key materialises an independent
# DB + role + Secret in this namespace, named `<ns>_<key>` (DB and
# role) and `<key>-postgres-credentials` (Secret). The role gets the
# same `GRANT ALL ON SCHEMA public` we hand out to the default DB —
# chart-side schema migrations own the ddl.
#
# Use case: one chart-managed app needs more than one logical
# Postgres database in the same tenant namespace (e.g. mm-core +
# Synapse share a tenant ns but each owns its own schema). The
# default DB controlled by `enabled` is independent — set
# `enabled: false` if every database the chart needs is named.
#
# Naming uses underscore separators because Postgres identifiers
# can't carry dashes without quoting; same convention as the default
# `pg_database` / `pg_user` already use.

# Composes the per-extra-database identifier (DB name + role name)
# through `terraform-null-label`. Same shape as the chart_oidc adoption:
# operator-readable, length-capped, and tagged consistently across Job
# + Secret labels.
#
# `delimiter = "_"` because Postgres identifiers must be quoted to use
# dashes — staying ASCII-safe lets every downstream `psql` interaction
# skip the extra quoting layer. `namespace` is already env-encoded
# (`phost-<slug>-<env>` → `phost_<slug>_<env>`), so `label_order =
# ["namespace", "name"]` skips the env attribute that chart_oidc's
# label adds — would just duplicate.
#
# `id_max_length = 63` is Postgres's identifier limit (`NAMEDATALEN -
# 1`); on overflow null-label truncates to cap-9 chars + delimiter +
# 8-char sha256 suffix to keep uniqueness. Long namespace + long key
# combos no longer silently get truncated by Postgres itself.
module "pg_extra_label" {
  for_each = local.pg_extra_databases

  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context       = module.project_label.context
  namespace     = replace(local.namespace, "-", "_") # "phost_<slug>_<env>" — overrides parent dashed form
  name          = each.key                           # the extra-database key
  delimiter     = "_"
  label_order   = ["namespace", "name"]
  id_max_length = 63
  tags = {
    "app.kubernetes.io/component" = "postgres-extra-db"
    "extra-database"              = each.key
  }
}

resource "random_password" "postgres_extra" {
  for_each = local.pg_extra_databases

  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "postgres_setup_extra_env" {
  for_each = local.pg_extra_databases

  metadata {
    name      = "postgres-setup-${local.namespace}-${each.key}"
    namespace = var.postgres_namespace
    labels    = module.project_label.tags
  }

  data = {
    SETUP_PASSWORD = "${random_password.postgres_extra[each.key].result}"
  }
}

resource "kubernetes_job_v1" "postgres_setup_extra" {
  for_each = local.pg_extra_databases

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "postgres-setup-${local.namespace}-${each.key}"
    namespace = var.postgres_namespace
    labels    = module.pg_extra_label[each.key].tags
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "postgres-setup-${local.namespace}-${each.key}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "postgres-setup"
          image = "postgres:18.6-alpine"

          # Password from a Secret, not the command line: Job specs are
          # readable far more widely than Secrets.
          env {
            name = "SETUP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres_setup_extra_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env_from {
            secret_ref {
              name = var.postgres_superuser_secret
            }
          }

          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${module.pg_extra_label[each.key].id}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${module.pg_extra_label[each.key].id}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${module.pg_extra_label[each.key].id}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${module.pg_extra_label[each.key].id}\\\" WITH LOGIN PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${module.pg_extra_label[each.key].id}\\\" WITH PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${module.pg_extra_label[each.key].id}\\\" TO \\\"${module.pg_extra_label[each.key].id}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${module.pg_extra_label[each.key].id} -c \"GRANT ALL ON SCHEMA public TO \\\"${module.pg_extra_label[each.key].id}\\\"\"",
            ])
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "2m"
  }
}

resource "kubernetes_secret_v1" "postgres_credentials_extra" {
  for_each = local.pg_extra_databases

  depends_on = [kubernetes_job_v1.postgres_setup_extra]

  metadata {
    name      = "${each.key}-postgres-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.pg_extra_label[each.key].tags
  }

  data = {
    PG_HOST      = var.postgres_host
    PG_PORT      = "5432"
    PG_DATABASE  = module.pg_extra_label[each.key].id
    PG_USER      = module.pg_extra_label[each.key].id
    PG_PASSWORD  = random_password.postgres_extra[each.key].result
    DATABASE_URL = "postgres://${module.pg_extra_label[each.key].id}:${random_password.postgres_extra[each.key].result}@${var.postgres_host}:5432/${module.pg_extra_label[each.key].id}"
  }
}

# ── Redis: per-namespace ACL user + key-prefix (only when needed) ─────────────

resource "random_password" "redis" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])
  length   = 24
  special  = false
}


# Same ACL line in the keeper's dedicated namespace (see modules/redis).
resource "kubernetes_secret_v1" "redis_acl_scoped" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])

  metadata {
    name      = "redis-acl-${local.namespace}"
    namespace = var.redis_acl_namespace
    labels = merge(module.project_label.tags, {
      "platform.local/redis-acl" = "true"
      "project-namespace"        = local.namespace
    })
  }

  data = {
    # `ACL SETUSER` argument string, applied verbatim by the keeper.
    setuser = join(" ", [
      local.redis_user,
      "on",
      "#${sha256(values(random_password.redis)[0].result)}",
      "resetkeys",
      "~${local.redis_key_prefix}*",
      "resetchannels",
      "&${local.redis_key_prefix}*",
      "&${local.namespace}::*",
      "+@all",
      "-@dangerous",
      "+INFO",
    ])
  }
}

resource "kubernetes_secret_v1" "redis_credentials" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])

  metadata {
    name      = "redis-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    REDIS_HOST       = var.redis_host
    REDIS_PORT       = "6379"
    REDIS_USER       = local.redis_user
    REDIS_PASSWORD   = values(random_password.redis)[0].result
    REDIS_KEY_PREFIX = local.redis_key_prefix
    # This Valkey build renames FLUSHDB/FLUSHALL away (destructive-command
    # hardening), so WP redis-cache's default FLUSHDB-based flush errors
    # with "unknown command". Selective flush switches it to SCAN+UNLINK
    # by key prefix — the object-cache drop-in reads this env at load.
    WP_REDIS_SELECTIVE_FLUSH = "1"
  }
}

# ── Ollama: no per-tenant credentials, just the shared endpoint URL ───────────
#
# Ollama has no native auth — every component on the platform shares the
# same instance and addresses it by plain URL. There's nothing tenant-
# specific to provision, so there's no setup Job; this Secret is a
# namespace-scoped convenience so `env_from.secret_ref` in
# modules/component works the same way as for `db_secret_name`.

resource "kubernetes_secret_v1" "ollama_endpoint" {
  for_each = local.needs_ollama ? toset(["enabled"]) : toset([])

  metadata {
    name      = "ollama-endpoint"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  # Different Ollama clients read different env names: the official
  # `ollama` CLI and the Python SDK want `OLLAMA_HOST`, Open WebUI
  # insists on `OLLAMA_BASE_URL`, some LangChain integrations use
  # `OLLAMA_API_BASE`. Emit them all pointing at the same URL so any
  # component can `ollama: true` without caring which client it uses.
  data = {
    OLLAMA_HOST     = var.ollama_url
    OLLAMA_BASE_URL = var.ollama_url
    OLLAMA_API_BASE = var.ollama_url
  }
}
