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
  # Singleton-ish toggle. All resources below use `for_each =
  # local.instances` — yields one instance keyed "enabled" when the
  # module is on, and an empty set when off. Pattern matches the
  # sibling terraform-k8s-addons module so `terraform state list`
  # looks uniform across the platform stack.
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Shorthand for the propagated null-label tag set used by every
  # k8s resource the module emits via `merge(local.tags, { … })`.
  # Existing-wins on key collision so the StatefulSet/Service
  # selector key `app=mysql` survives intact.
  tags = module.label.tags
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "mysql"
  tags = {
    "app.kubernetes.io/component" = "mysql"
  }
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
    labels    = local.tags
  }

  data = {
    MYSQL_ROOT_PASSWORD = random_password.root["enabled"].result
  }
}

# ── Persistent storage ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "mysql" {
  for_each = local.instances

  metadata {
    name   = "platform-mysql-data"
    labels = local.tags
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
    labels    = local.tags
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
    labels    = merge(local.tags, { app = "mysql" })
  }

  spec {
    replicas     = 1
    service_name = "mysql"

    selector {
      match_labels = { app = "mysql" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "mysql" })
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
    labels    = merge(local.tags, { app = "mysql" })
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

#
# All outputs collapse to `null` when the module is disabled. Downstream
# consumers (modules/project) pass these through to tenant-side
# precondition checks, so a disabled MySQL produces a clear error the
# first time a component asks for it instead of a silent mis-deploy.
