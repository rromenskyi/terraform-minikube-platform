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

# =============================================================================
# Infisical — Phase 0: bring it up empty, login as recovery admin.
# =============================================================================
#
# This is the platform's secrets store. Phase 0 stands up the server +
# Postgres-side schema + recovery admin and that's it — no Zitadel
# OIDC integration (Phase 1), no consumer rewiring (Phase 2+), no
# secret migration (Phase 3). After Phase 0 lands, the operator can
# log in at `https://<hostname>` with the recovery-admin email +
# password and click around to sanity-check; nothing else changes.
#
# Bootstrap pattern mirrors `modules/zitadel`:
#   1. random_password resources for encryption_key / auth_secret /
#      db_password / recovery_admin (stay in TF state — bootstrap
#      material can't live in Infisical itself).
#   2. Postgres setup Job (idempotent CREATE DATABASE / ROLE / GRANT).
#   3. Deployment with env_from on the Secret.
#   4. Recovery-admin signup Job hits `/api/v1/admin/signup` after the
#      pod's `/api/status` is healthy. Idempotent: the endpoint refuses
#      a second signup once an admin exists, the curl wrapper catches
#      that and exits 0.
#
# Phase 1 (deferred) extends the same bootstrap Job to call
# `/api/v1/sso/oidc/...` with a Zitadel OIDC client provisioned via
# `modules/zitadel-app`. Phase 2 introduces the `infisical-agent`
# sidecar that materialises k8s Secrets from Infisical paths.

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "enabled" {
  description = "Deploy Infisical. When false, no resources are created."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Infisical lives in. Expected to exist already (typically `platform`)."
  type        = string
  default     = "platform"
}

variable "hostname" {
  description = "Public hostname Infisical answers on (e.g. `secrets.example.com`). Drives `SITE_URL` and the IngressRoute Host(...) match."
  type        = string
  default     = ""
}

variable "image" {
  description = "Infisical container image. Pinned tag — `:latest` would silently pull schema changes between restarts. The official self-host repo is `infisical/infisical`; the `infisical/infisical-cli` image is a separate animal (CLI client used in the agent sidecar in Phase 2)."
  type        = string
  default     = "infisical/infisical:v0.74.0-postgres"
}

variable "postgres_host" {
  description = "In-cluster hostname of the shared PostgreSQL. Required — Infisical has no internal-store fallback (unlike Stalwart's RocksDB)."
  type        = string
  default     = null
}

variable "postgres_superuser_secret" {
  description = "Name of the Secret (in `postgres_namespace`) holding the superuser password used by the per-service setup Job. Same Secret the Zitadel module consumes."
  type        = string
  default     = null
}

variable "postgres_namespace" {
  description = "Namespace where the shared PostgreSQL lives — needed because the setup Job runs in `var.namespace` but the Secret it env_from's lives in the platform shared-services namespace, so we use a same-namespace copy of the superuser_secret. `null` defaults to var.namespace."
  type        = string
  default     = null
}

variable "redis_host" {
  description = "In-cluster hostname of the shared Redis. Required — Infisical uses Redis for Bull queues + rate limiting, no fallback."
  type        = string
  default     = null
}

variable "redis_default_secret" {
  description = "Name of the Secret (in `redis_namespace`) holding the default-user password. Read at Deployment time to construct REDIS_URL."
  type        = string
  default     = null
}

variable "redis_namespace" {
  description = "Namespace where the shared Redis lives. `null` defaults to var.namespace."
  type        = string
  default     = null
}

variable "recovery_admin_email" {
  description = "Email address for the bootstrap admin account. The signup Job uses this + the generated password to call `/api/v1/admin/signup`. Required when enabled — there's no sane default."
  type        = string
  default     = ""
}

variable "memory_request" {
  type    = string
  default = "256Mi"
}

variable "memory_limit" {
  type    = string
  default = "1Gi"
}

variable "cpu_request" {
  type    = string
  default = "100m"
}

variable "cpu_limit" {
  type    = string
  default = "1"
}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  db_name = "platform_infisical"
  db_user = "platform_infisical"

  postgres_ns = coalesce(var.postgres_namespace, var.namespace)
  redis_ns    = coalesce(var.redis_namespace, var.namespace)

  # Same-namespace copy of the upstream Secret(s) — k8s env_from can't
  # cross namespaces, so the setup Job needs a local copy of the
  # postgres superuser secret (same trick the Zitadel module uses
  # implicitly because it lives in the platform namespace alongside
  # postgres). This module makes the namespace assumption explicit so
  # an operator could place Infisical somewhere else if they wanted.
  copy_postgres_secret = var.enabled && local.postgres_ns != var.namespace
  copy_redis_secret    = var.enabled && local.redis_ns != var.namespace
}

# -----------------------------------------------------------------------------
# Bootstrap material — every value lives in TF state, never in Infisical.
# -----------------------------------------------------------------------------

# 32-char key Infisical uses to encrypt secrets-at-rest in Postgres.
# CIRCULAR if it lived in Infisical; TF state is the platform's effective
# secret store for bootstrap material today, and remains so after this
# module lands. Lose the key → Postgres rows are unreadable. Re-bootstrap
# wipes alongside everything else (same trade-off Zitadel makes with its
# masterkey — see `modules/zitadel/main.tf`).
resource "random_password" "encryption_key" {
  for_each = local.instances

  length  = 32
  special = false
}

# JWT signing key. Sessions issued before a rotation become invalid;
# survives normal pod restarts because it's in a Secret + TF state.
resource "random_password" "auth_secret" {
  for_each = local.instances

  length  = 32
  special = false
}

# Postgres role password for the `platform_infisical` user. Distinct
# from the postgres-superuser password (which only the setup Job
# uses). Special chars omitted because the value goes into a postgres
# connection URI — `:` and `@` would need percent-encoding.
resource "random_password" "db" {
  for_each = local.instances

  length  = 32
  special = false
}

# Bootstrap admin — break-glass + Phase 0 login path before OIDC SSO
# arrives in Phase 1. Same complexity profile as Zitadel's admin
# password so the operator can paste it without surprise.
resource "random_password" "recovery_admin" {
  for_each = local.instances

  length           = 24
  override_special = "!@#%&*+_-"
  min_special      = 2
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

# -----------------------------------------------------------------------------
# Cross-namespace Secret copies — Infisical Deployment + setup Job both
# need to env_from these, and env_from is namespace-scoped.
# -----------------------------------------------------------------------------

# Postgres superuser secret copied into Infisical's namespace when the
# operator placed Infisical somewhere other than the platform shared-
# services namespace. The module assumes the source Secret has a
# `POSTGRES_PASSWORD` key — same shape `modules/postgres` emits.
data "kubernetes_secret_v1" "postgres_superuser_src" {
  for_each = local.copy_postgres_secret ? local.instances : toset([])

  metadata {
    name      = var.postgres_superuser_secret
    namespace = local.postgres_ns
  }
}

resource "kubernetes_secret_v1" "postgres_superuser_local" {
  for_each = local.copy_postgres_secret ? local.instances : toset([])

  metadata {
    name      = "${var.postgres_superuser_secret}-infisical-copy"
    namespace = var.namespace
  }

  data = data.kubernetes_secret_v1.postgres_superuser_src["enabled"].data
}

# Redis default-user secret copy. Same shape — REDIS_PASSWORD key.
data "kubernetes_secret_v1" "redis_default_src" {
  for_each = local.copy_redis_secret ? local.instances : toset([])

  metadata {
    name      = var.redis_default_secret
    namespace = local.redis_ns
  }
}

resource "kubernetes_secret_v1" "redis_default_local" {
  for_each = local.copy_redis_secret ? local.instances : toset([])

  metadata {
    name      = "${var.redis_default_secret}-infisical-copy"
    namespace = var.namespace
  }

  data = data.kubernetes_secret_v1.redis_default_src["enabled"].data
}

# Resolved Secret name the Job/Deployment will env_from for postgres
# password + redis password. Local-copy when cross-namespace, source
# Secret name otherwise.
locals {
  postgres_superuser_local_name = local.copy_postgres_secret ? kubernetes_secret_v1.postgres_superuser_local["enabled"].metadata[0].name : var.postgres_superuser_secret
  redis_default_local_name      = local.copy_redis_secret ? kubernetes_secret_v1.redis_default_local["enabled"].metadata[0].name : var.redis_default_secret
}

# -----------------------------------------------------------------------------
# Per-service Secret — env_from'd by the Deployment.
# -----------------------------------------------------------------------------

resource "kubernetes_secret_v1" "infisical" {
  for_each = local.instances

  metadata {
    name      = "infisical"
    namespace = var.namespace
  }

  data = {
    encryption_key          = random_password.encryption_key["enabled"].result
    auth_secret             = random_password.auth_secret["enabled"].result
    db_password             = random_password.db["enabled"].result
    recovery_admin_password = random_password.recovery_admin["enabled"].result
    recovery_admin_email    = var.recovery_admin_email
  }
}

# -----------------------------------------------------------------------------
# Postgres setup Job — direct port of modules/zitadel.
# -----------------------------------------------------------------------------

resource "kubernetes_job_v1" "postgres_setup" {
  for_each = local.instances

  metadata {
    name      = "infisical-postgres-setup"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "infisical"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = { job = "infisical-postgres-setup" }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "postgres-setup"
          image = "postgres:16-alpine"

          env_from {
            secret_ref {
              name = local.postgres_superuser_local_name
            }
          }

          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }

          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.db_name}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${local.db_name}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.db_user}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${local.db_user}\\\" WITH LOGIN PASSWORD '${random_password.db["enabled"].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${local.db_user}\\\" WITH PASSWORD '${random_password.db["enabled"].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${local.db_name}\\\" TO \\\"${local.db_user}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${local.db_name} -c \"GRANT ALL ON SCHEMA public TO \\\"${local.db_user}\\\"\"",
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

# -----------------------------------------------------------------------------
# Deployment — single replica, Recreate. Runs DB schema migrations on
# every boot (Infisical's start script handles `npm run migration:latest`
# idempotently when DB_CONNECTION_URI points at a writable Postgres).
# -----------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "infisical" {
  for_each = local.instances

  depends_on = [kubernetes_job_v1.postgres_setup]

  metadata {
    name      = "infisical"
    namespace = var.namespace
    labels    = { app = "infisical" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "infisical" }
    }

    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "infisical" }
      }

      spec {
        # Same Zitadel-era footgun: legacy docker-link `<SERVICE>_PORT`
        # envs auto-injected per Service in the namespace. Some Node
        # process configs read `PORT` from env and crash on
        # `tcp://...`. Cheap insurance.
        enable_service_links = false

        container {
          name  = "infisical"
          image = var.image

          port {
            name           = "http"
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.infisical["enabled"].metadata[0].name
            }
          }

          # ── Required runtime config ───────────────────────────────
          env {
            name = "ENCRYPTION_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.infisical["enabled"].metadata[0].name
                key  = "encryption_key"
              }
            }
          }

          env {
            name = "AUTH_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.infisical["enabled"].metadata[0].name
                key  = "auth_secret"
              }
            }
          }

          # K8s `$(VAR)` env substitution only resolves a reference to a
          # var declared EARLIER in the same env list — declare passwords
          # first so the URI strings below pick them up. A reference to
          # a later var falls through as a literal `$(NAME)` string,
          # which Infisical then sends to Redis verbatim and gets
          # `WRONGPASS` from the AUTH command.
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.infisical["enabled"].metadata[0].name
                key  = "db_password"
              }
            }
          }

          env {
            name = "REDIS_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.redis_default_local_name
                key  = "REDIS_PASSWORD"
              }
            }
          }

          env {
            name  = "DB_CONNECTION_URI"
            value = "postgres://${local.db_user}:$(DB_PASSWORD)@${var.postgres_host}:5432/${local.db_name}"
          }

          env {
            name  = "REDIS_URL"
            value = "redis://default:$(REDIS_PASSWORD)@${var.redis_host}:6379"
          }

          env {
            name  = "SITE_URL"
            value = "https://${var.hostname}"
          }

          # Don't phone home. Self-hosted, no behavioural data leaves.
          env {
            name  = "TELEMETRY_ENABLED"
            value = "false"
          }

          # API listen port. Default 8080.
          env {
            name  = "PORT"
            value = "8080"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          startup_probe {
            http_get {
              path = "/api/status"
              port = 8080
            }
            failure_threshold = 60
            period_seconds    = 5
          }

          liveness_probe {
            http_get {
              path = "/api/status"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/api/status"
              port = 8080
            }
            period_seconds  = 10
            timeout_seconds = 3
          }
        }
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Service
# -----------------------------------------------------------------------------

resource "kubernetes_service_v1" "infisical" {
  for_each = local.instances

  metadata {
    name      = "infisical"
    namespace = var.namespace
    labels    = { app = "infisical" }
  }

  spec {
    selector = { app = "infisical" }
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

# -----------------------------------------------------------------------------
# Routing — via the platform's `kind: external` component pattern.
#
# IngressRoute + Cloudflare Tunnel ingress_rule are NOT emitted from
# this module — they ride the same pipeline as Stalwart/oauth2-proxy:
# `config/components/infisical.yaml` is `kind: external` pointing at
# this module's Service, and the operator wires a route under
# `config/domains/<x>.yaml#envs.<env>.routes` (e.g.
# `secrets: infisical`). That puts the hostname into
# `local.all_hostnames` (cloudflared sees it) and into the project's
# IngressRoute (Traefik routes it). Single source of truth for every
# routed hostname; no module-side IngressRoute fighting the project
# module for the same Host(...) match.
#
# No random URL prefix (unlike Stalwart admin): Phase 1 puts Zitadel
# OIDC behind the login flow, which is a real auth gate. URL obscurity
# without an auth gate is theatre; with an auth gate it's redundant.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Recovery admin signup Job — calls /api/v1/admin/signup once per
# bootstrap. Idempotent: the endpoint refuses a second call once an
# admin exists, the curl wrapper treats that response as success.
# -----------------------------------------------------------------------------

resource "kubernetes_job_v1" "recovery_admin_signup" {
  for_each = local.instances

  depends_on = [kubernetes_deployment_v1.infisical]

  metadata {
    # Suffix carries the email so a change to recovery_admin_email
    # forces a fresh Job. Re-running the signup against an existing
    # admin email is a no-op via the idempotency check inside the
    # script.
    name      = "infisical-recovery-admin-signup"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "infisical"
    }
  }

  spec {
    backoff_limit = 5

    template {
      metadata {
        labels = { job = "infisical-recovery-admin-signup" }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "signup"
          image = "curlimages/curl:8.10.1"

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.infisical["enabled"].metadata[0].name
            }
          }

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }

          # Wait for /api/status; then POST signup. If admin already
          # exists, Infisical returns 4xx — treat as success so re-
          # applies are idempotent.
          command = [
            "sh", "-c",
            <<-EOT
            set -eu
            URL="http://infisical.${var.namespace}.svc.cluster.local"

            echo "[signup] waiting for $URL/api/status..."
            until curl -fsS -m 5 "$URL/api/status" >/dev/null 2>&1; do
              sleep 2
            done
            echo "[signup] API ready"

            BODY=$(printf '{"email":"%s","password":"%s","firstName":"Recovery","lastName":"Admin","organizationName":"platform"}' \
              "$recovery_admin_email" "$recovery_admin_password")

            HTTP_CODE=$(curl -s -o /tmp/resp -w '%%{http_code}' \
              -X POST -H 'Content-Type: application/json' \
              -d "$BODY" \
              "$URL/api/v1/admin/signup")

            echo "[signup] HTTP $HTTP_CODE"
            cat /tmp/resp || true

            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
              echo "[signup] admin created"
              exit 0
            fi

            # Admin already exists — Infisical's response varies by
            # version; match common bodies and accept.
            if grep -qE '(already.*exist|already.*set|admin.*created)' /tmp/resp 2>/dev/null; then
              echo "[signup] admin already exists — treating as success"
              exit 0
            fi

            echo "[signup] unexpected response — failing"
            exit 1
            EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value = var.namespace
}

output "hostname" {
  value = var.hostname
}

output "service_name" {
  value = var.enabled ? kubernetes_service_v1.infisical["enabled"].metadata[0].name : null
}

output "port" {
  value = 80
}

output "url" {
  description = "Public Infisical URL — use as `terraform output -raw infisical_url`."
  value       = var.enabled ? "https://${var.hostname}" : null
}

output "recovery_admin_email" {
  value = var.recovery_admin_email
}

output "recovery_admin_password" {
  description = "Bootstrap admin password. Break-glass after Phase 1 lands OIDC SSO; primary login path until then."
  value       = var.enabled ? random_password.recovery_admin["enabled"].result : null
  sensitive   = true
}
