terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# Seafile community edition — file storage + library sync
# =============================================================================
#
# Single-pod Deployment of the upstream `seafileltd/seafile-mc:13.x`
# image (all-in-one bundle: Seahub Django UI + ccnet + fileserver +
# memcached binary, Redis is the canonical cache backend since 13).
# Backed by:
#   - the platform's shared MySQL instance (Seafile 13 CE is MySQL-only,
#     Postgres unsupported upstream); engine pre-creates the database
#     and a scoped user via a one-shot setup Job similar to
#     `modules/project::mysql_setup`.
#   - the platform's shared Redis instance for cache (Seafile 13 dropped
#     memcached as the recommended cache; Redis Sentinel/single-node
#     both work, single-node fits the home-lab shape).
#   - a Longhorn-backed PVC mounted at `/shared` (Seafile convention)
#     for libraries, blobs, history, ccnet state.
#
# OIDC integration: Seahub reads OAuth/OIDC config from
# `seahub_settings.py` (Python config — no env-var path). Engine
# templates the file from a Zitadel client (created via
# `modules/zitadel-app` at root) and mounts as a ConfigMap subPath
# overlaid on `/shared/seafile/conf/seahub_settings.py`. Auto-
# provisions Seafile users on first SSO login
# (`OAUTH_CREATE_UNKNOWN_USER = True`).
#
# Behind Traefik: the project route sends everything to the image's
# nginx on :80, which serves Seahub and proxies `/seafhttp` to the
# fileserver (:8082). The bundled Caddy is bypassed (Traefik does TLS
# at the tunnel boundary; Seahub is plain HTTP behind it).

locals {
  enabled = var.enabled
  set     = local.enabled ? toset(["enabled"]) : toset([])

  tags = module.label.tags

  # Seahub settings — OAuth/OIDC, public service URL, CSRF trusted
  # origins. Delivered through the seahub-extra Secret; its checksum
  # annotation rolls the pod on change.
  seahub_settings_py = <<-EOT
    # Managed by terraform (modules/seafile, seahub-extra Secret).

    # Public-facing URL — generated download links / OAuth callback
    # construction use this prefix.
    SERVICE_URL = "https://${var.external_hostname}"
    FILE_SERVER_ROOT = "https://${var.external_hostname}/seafhttp"
    CSRF_TRUSTED_ORIGINS = ["https://${var.external_hostname}"]

    # Behind a TLS-terminating reverse proxy (Traefik), the Origin
    # header is from the public hostname. Trust the X-Forwarded-Proto
    # header so Seahub generates `https://` links.
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")

    %{if var.oidc_client_id != ""}
    # ── OIDC via Zitadel ───────────────────────────────────────────
    ENABLE_OAUTH = True
    OAUTH_CREATE_UNKNOWN_USER = True
    OAUTH_ACTIVATE_USER_AFTER_CREATION = True
    OAUTH_CLIENT_ID = "${var.oidc_client_id}"
    OAUTH_CLIENT_SECRET = "${var.oidc_client_secret}"
    OAUTH_REDIRECT_URL = "https://${var.external_hostname}/oauth/callback/"
    OAUTH_PROVIDER_DOMAIN = "${replace(replace(var.oidc_issuer_url, "https://", ""), "/", "")}"
    OAUTH_AUTHORIZATION_URL = "${var.oidc_issuer_url}/oauth/v2/authorize"
    OAUTH_TOKEN_URL = "${var.oidc_issuer_url}/oauth/v2/token"
    OAUTH_USER_INFO_URL = "${var.oidc_issuer_url}/oidc/v1/userinfo"
    OAUTH_SCOPE = ["openid", "profile", "email"]
    # `sub→uid` is mandatory since Seafile 11 (stable internal user id
    # mapping). `email` and `name` populate the displayed profile.
    OAUTH_ATTRIBUTE_MAP = {
        "sub":   (True,  "uid"),
        "email": (False, "contact_email"),
        "name":  (False, "name"),
    }
    %{endif}
  EOT
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "seafile"
  tags = {
    "app.kubernetes.io/component" = "seafile"
  }
}

# ── Namespace ──────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  for_each = local.set

  metadata {
    name = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "seafile"
    })
  }
}

# ── Generated secrets ──────────────────────────────────────────────────────
#
# All three are random-per-state. Operator can rotate via Vault once
# the platform-wide vault-mode pattern lands here; for now they live
# in `kubernetes_secret_v1` as standard random_password output.
#
#   * admin password — initial Seahub super-user, ignored after first
#     boot (Seafile bakes the value into its DB on bootstrap and
#     surfaces it to the operator via the `admin_email_output`).
#   * MySQL user password — scoped to the `seafile` DB.
#   * JWT private key — Seafile 13 uses this for inter-service auth
#     (Seahub ↔ fileserver tokens). Required env var.

resource "random_password" "admin" {
  for_each = local.set

  length  = 24
  special = false
}

resource "random_password" "db" {
  for_each = local.set

  length  = 32
  special = false
}

resource "random_password" "jwt" {
  for_each = local.set

  length  = 40
  special = false
}

# ── Bootstrap Secret consumed by the pod's envFrom ──────────────────────────

resource "kubernetes_secret_v1" "bootstrap" {
  for_each = local.set

  metadata {
    name      = "seafile-bootstrap"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    INIT_SEAFILE_ADMIN_EMAIL         = var.admin_email
    INIT_SEAFILE_ADMIN_PASSWORD      = random_password.admin["enabled"].result
    SEAFILE_MYSQL_DB_HOST            = var.mysql_host
    SEAFILE_MYSQL_DB_PORT            = tostring(var.mysql_port)
    SEAFILE_MYSQL_DB_USER            = "seafile"
    SEAFILE_MYSQL_DB_PASSWORD        = random_password.db["enabled"].result
    SEAFILE_MYSQL_DB_CCNET_DB_NAME   = "ccnet_db"
    SEAFILE_MYSQL_DB_SEAFILE_DB_NAME = "seafile_db"
    SEAFILE_MYSQL_DB_SEAHUB_DB_NAME  = "seahub_db"
    JWT_PRIVATE_KEY                  = random_password.jwt["enabled"].result
    SEAFILE_SERVER_HOSTNAME          = var.external_hostname
    SEAFILE_SERVER_PROTOCOL          = "https"
    CACHE_PROVIDER                   = "redis"
    REDIS_HOST                       = var.redis_host
    REDIS_PORT                       = tostring(var.redis_port)
    REDIS_PASSWORD                   = var.redis_password
    TIME_ZONE                        = var.timezone
    SEAFILE_LOG_TO_STDOUT            = "true"
  }
}

# Platform settings for Seahub (public URL, proxy headers, Zitadel OIDC).
# Seafile's first boot writes `seahub_settings.py` itself (DB creds,
# SECRET_KEY), so the file cannot be mounted over. The pod's postStart
# appends one line to it that executes this file; being last, these
# values win over anything set earlier in the file. A Secret, because
# the OIDC client secret is in it.
resource "kubernetes_secret_v1" "seahub_extra" {
  for_each = local.set

  metadata {
    name      = "seafile-seahub-extra"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    "seahub_settings_extra.py" = local.seahub_settings_py
  }
}

# ── Persistent volume for /shared ───────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "data" {
  for_each = local.set

  metadata {
    name      = "seafile-data"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# ── MySQL setup Job — create databases + user, idempotent ───────────────────
#
# Seafile's `INIT_SEAFILE_MYSQL_ROOT_PASSWORD` env var would let the
# bootstrap script create everything itself, but that requires
# embedding the MySQL root password in the same Secret as the running
# pod — wider blast radius than necessary. Engine instead does the
# CREATE DATABASE + GRANT once via a privileged Job, then drops the
# root password from the bootstrap secret entirely (so the running
# pod only knows its scoped `seafile` user creds).

resource "kubernetes_secret_v1" "mysql_setup_env" {
  for_each = local.set

  metadata {
    name      = "seafile-mysql-setup"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    SETUP_PASSWORD = "${random_password.db["enabled"].result}"
  }
}

resource "kubernetes_job_v1" "mysql_setup" {
  for_each = local.set

  metadata {
    name      = "seafile-mysql-setup-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = local.tags
      }
      spec {
        restart_policy = "OnFailure"

        container {
          name  = "mysql-setup"
          image = "mysql:8.4.11"

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }

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

          env {
            name  = "MYSQL_PWD"
            value = var.mysql_root_password
          }

          command = [
            "sh",
            "-c",
            <<-EOT
              set -eu
              mysql -h ${var.mysql_host} -P ${var.mysql_port} -uroot <<SQL
              CREATE DATABASE IF NOT EXISTS ccnet_db   CHARACTER SET utf8mb4;
              CREATE DATABASE IF NOT EXISTS seafile_db CHARACTER SET utf8mb4;
              CREATE DATABASE IF NOT EXISTS seahub_db  CHARACTER SET utf8mb4;
              CREATE USER IF NOT EXISTS 'seafile'@'%' IDENTIFIED BY '$SETUP_PASSWORD';
              ALTER USER 'seafile'@'%' IDENTIFIED BY '$SETUP_PASSWORD';
              GRANT ALL PRIVILEGES ON ccnet_db.*   TO 'seafile'@'%';
              GRANT ALL PRIVILEGES ON seafile_db.* TO 'seafile'@'%';
              GRANT ALL PRIVILEGES ON seahub_db.*  TO 'seafile'@'%';
              FLUSH PRIVILEGES;
              SQL
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

  lifecycle {
    ignore_changes = [metadata[0].name]
  }
}

# ── Deployment ──────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  for_each = local.set

  depends_on = [
    kubernetes_job_v1.mysql_setup,
    kubernetes_persistent_volume_claim_v1.data,
  ]

  metadata {
    name      = "seafile"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels = merge(local.tags, {
      "app" = "seafile"
    })
  }

  spec {
    replicas = 1

    # Recreate not RollingUpdate — Seafile holds open file handles on
    # the shared PVC; two pods running simultaneously corrupt the
    # ccnet/seafile data dir.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app" = "seafile"
      }
    }

    template {
      metadata {
        labels = merge(local.tags, {
          "app" = "seafile"
        })
        annotations = {
          # Per the platform consumer-checksum convention — re-roll
          # the pod when bootstrap secret rotates.
          "checksum/bootstrap"    = sha256(jsonencode(kubernetes_secret_v1.bootstrap["enabled"].data))
          "checksum/seahub-extra" = sha256(local.seahub_settings_py)
        }
      }
      spec {
        node_selector = var.node_selector
        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = lookup(toleration.value, "key", null)
            operator = lookup(toleration.value, "operator", "Exists")
            value    = lookup(toleration.value, "value", null)
            effect   = lookup(toleration.value, "effect", null)
          }
        }

        container {
          name              = "seafile"
          image             = "seafileltd/seafile-mc:${var.image_tag}"
          image_pull_policy = "IfNotPresent"

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.bootstrap["enabled"].metadata[0].name
            }
          }

          port {
            name           = "seahub"
            container_port = 80
          }
          port {
            name           = "fileserver"
            container_port = 8082
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

          volume_mount {
            name       = "data"
            mount_path = "/shared"
          }

          volume_mount {
            name       = "seahub-extra"
            mount_path = "/etc/seafile-extra"
            read_only  = true
          }

          # Hooks the seahub-extra Secret into seahub_settings.py once
          # (see the Secret). On a brand-new volume the file appears only
          # after bootstrap, so the first boot needs one pod restart for
          # these settings to take effect. Never fails the container.
          lifecycle {
            post_start {
              exec {
                command = ["/bin/sh", "-c", <<-EOT
                  f=/shared/seafile/conf/seahub_settings.py
                  line='exec(open("/etc/seafile-extra/seahub_settings_extra.py").read())  # managed by terraform'
                  i=0
                  while [ ! -f "$f" ] && [ $i -lt 600 ]; do sleep 2; i=$((i+2)); done
                  [ -f "$f" ] && ! grep -qF "$line" "$f" && printf '\n%s\n' "$line" >> "$f"
                  exit 0
                EOT
                ]
              }
            }
          }

          # Seafile's all-in-one bootstrap is slow on first start
          # (MySQL schema population, Django migrations, ccnet init,
          # nginx upstream warmup). Liveness with a tight kill timer
          # creates restart-loop death spiral on first-boot. Drop
          # liveness entirely and rely on readiness — restarting an
          # actually-deadlocked Seafile is operator's call, not
          # kubelet's. Readiness initialDelay set generously (5min)
          # so probe doesn't ding the pod while bootstrap is still
          # populating the DB.
          # TCP probe (not HTTP) because Seahub's `/` returns 302 to
          # `/accounts/login/`, kubelet follows that, login render
          # can take >15s on a constrained node, probe times out
          # waiting for headers, pod never reaches Ready. TCP only
          # checks nginx is listening on :80 — sufficient signal
          # for ingress routing; deeper health goes through real
          # Seahub paths from external clients.
          readiness_probe {
            tcp_socket {
              port = 80
            }
            initial_delay_seconds = 120
            period_seconds        = 15
            timeout_seconds       = 3
            failure_threshold     = 10
            success_threshold     = 1
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data["enabled"].metadata[0].name
          }
        }

        volume {
          name = "seahub-extra"
          secret {
            secret_name = kubernetes_secret_v1.seahub_extra["enabled"].metadata[0].name
          }
        }

      }
    }
  }
}

# ── Service ─────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  for_each = local.set

  metadata {
    name      = "seafile"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app" = "seafile"
    }

    port {
      name        = "seahub"
      port        = 80
      target_port = "seahub"
      protocol    = "TCP"
    }

    port {
      name        = "fileserver"
      port        = 8082
      target_port = "fileserver"
      protocol    = "TCP"
    }
  }
}

# No `/seafhttp` route of its own: the image's nginx (behind the project
# route on :80) already proxies `/seafhttp` to the fileserver on :8082.

