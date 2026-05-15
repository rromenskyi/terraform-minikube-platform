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
# Behind Traefik: pod exposes :8000 (Seahub) and :8082 (fileserver
# for raw blob upload/download). IngressRoute splits the traffic by
# path — `/seafhttp` → fileserver after StripPrefix, everything else
# → Seahub. The bundled Caddy is bypassed (Traefik does TLS at the
# tunnel boundary; Seahub is plain HTTP behind it).

locals {
  enabled  = var.enabled
  set      = local.enabled ? toset(["enabled"]) : toset([])
  oidc_set = (var.enabled && var.oidc_client_id != "") ? toset(["enabled"]) : toset([])

  tags = module.label.tags

  # Seahub Python settings file — OAuth/OIDC, public service URL,
  # CSRF trusted origins. Mounted as a ConfigMap subPath overlay so
  # operator-side rotations (e.g. flipping a claim mapping) trigger
  # a Pod re-roll via the checksum annotation.
  seahub_settings_py = <<-EOT
    # Managed by terraform — modules/seafile/main.tf. Edits here are
    # overwritten on every `./tf apply`.

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
    INIT_SEAFILE_MYSQL_ROOT_PASSWORD = var.mysql_root_password
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
    TIME_ZONE                        = var.timezone
    SEAFILE_LOG_TO_STDOUT            = "true"
  }
}

# ── Seahub settings ConfigMap (OIDC + reverse-proxy URL) ────────────────────

resource "kubernetes_config_map_v1" "seahub_settings" {
  for_each = local.set

  metadata {
    name      = "seafile-seahub-settings"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    "seahub_settings.py" = local.seahub_settings_py
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
          image = "mysql:8.0"

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
              CREATE USER IF NOT EXISTS 'seafile'@'%' IDENTIFIED BY '${random_password.db["enabled"].result}';
              ALTER USER 'seafile'@'%' IDENTIFIED BY '${random_password.db["enabled"].result}';
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
          # the pod when bootstrap secret or seahub settings rotate.
          "checksum/bootstrap"       = sha256(jsonencode(kubernetes_secret_v1.bootstrap["enabled"].data))
          "checksum/seahub-settings" = sha256(local.seahub_settings_py)
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

          # Overlay seahub_settings.py inside the bootstrapped conf
          # dir. subPath keeps the rest of `/shared/seafile/conf/`
          # writable for the Seafile installer to populate other
          # config files on first boot.
          volume_mount {
            name       = "seahub-settings"
            mount_path = "/shared/seafile/conf/seahub_settings.py"
            sub_path   = "seahub_settings.py"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 10
            failure_threshold     = 6
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 180
            period_seconds        = 60
            timeout_seconds       = 15
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data["enabled"].metadata[0].name
          }
        }

        volume {
          name = "seahub-settings"
          config_map {
            name = kubernetes_config_map_v1.seahub_settings["enabled"].metadata[0].name
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

# ── Traefik IngressRoute ────────────────────────────────────────────────────
#
# Splits traffic by path:
#   /seafhttp/* → fileserver (port 8082), strip the `/seafhttp` prefix
#   everything else → Seahub (port 80)

resource "kubernetes_manifest" "fileserver_strip_middleware" {
  for_each = local.set

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "seafile-strip-fileserver"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = local.tags
    }
    spec = {
      stripPrefix = {
        prefixes = ["/seafhttp"]
      }
    }
  }
}

resource "kubectl_manifest" "ingressroute" {
  for_each = local.set

  depends_on = [
    kubernetes_service_v1.this,
    kubernetes_manifest.fileserver_strip_middleware,
  ]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "seafile"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = local.tags
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [
        {
          match = "Host(`${var.external_hostname}`) && PathPrefix(`/seafhttp`)"
          kind  = "Rule"
          # Higher priority so this route wins over the catch-all
          # below; otherwise PathPrefix matchers can race.
          priority = 100
          services = [
            {
              name = kubernetes_service_v1.this["enabled"].metadata[0].name
              port = 8082
            }
          ]
          middlewares = [
            {
              name      = "seafile-strip-fileserver"
              namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
            }
          ]
        },
        {
          match = "Host(`${var.external_hostname}`)"
          kind  = "Rule"
          services = [
            {
              name = kubernetes_service_v1.this["enabled"].metadata[0].name
              port = 80
            }
          ]
        }
      ]
    }
  })
}
