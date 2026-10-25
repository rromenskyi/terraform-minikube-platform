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

  # Storage: hostPath (default) or a dynamic volume (modules/volume-seed).
  csi_storage   = var.storage_class != ""
  seed          = local.csi_storage && var.storage_seed_node != ""
  data_sub_path = local.csi_storage ? module.volume_seed.sub_path : null

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

# mysqld runs this file on every start. The image sets the root password
# only when it initialises an empty data dir, so after state is
# regenerated (or the password rotated) the Secret and the server would
# disagree; re-asserting it here keeps them in sync.
resource "kubernetes_secret_v1" "mysql_root_init" {
  for_each = local.instances

  metadata {
    name      = "mysql-root-init"
    namespace = var.namespace
    labels    = local.tags
  }

  data = {
    "init.sql" = <<-SQL
      ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '${random_password.root["enabled"].result}';
      ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '${random_password.root["enabled"].result}';
    SQL
  }
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
  # Kept while seeding (modules/volume-seed).
  for_each = local.csi_storage && !local.seed ? toset([]) : local.instances

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
  for_each = local.csi_storage && !local.seed ? toset([]) : local.instances

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

# With a StorageClass: a dynamic volume, layout per modules/volume-seed.
resource "kubernetes_persistent_volume_claim_v1" "mysql_data" {
  for_each = local.csi_storage ? local.instances : toset([])

  metadata {
    name      = "data-mysql"
    namespace = var.namespace
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }

  # WaitForFirstConsumer: binds when the pod is scheduled.
  wait_until_bound = false
}

module "volume_seed" {
  source = "../volume-seed"
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
        # While seeding, also pinned to the node with the old hostPath data.
        node_selector = local.seed || length(var.node_selector) > 0 ? merge(
          var.node_selector,
          local.seed ? { "kubernetes.io/hostname" = var.storage_seed_node } : {},
        ) : null

        # Only on nodes where the volume can attach (volume_node_label), and
        # preferably on the nodes in preferred_node_affinity.
        dynamic "affinity" {
          for_each = (local.csi_storage && var.volume_node_label != "") || length(var.preferred_node_affinity) > 0 ? [1] : []
          content {
            node_affinity {
              dynamic "required_during_scheduling_ignored_during_execution" {
                for_each = local.csi_storage && var.volume_node_label != "" ? [var.volume_node_label] : []
                content {
                  node_selector_term {
                    match_expressions {
                      key      = required_during_scheduling_ignored_during_execution.value
                      operator = "Exists"
                    }
                  }
                }
              }
              dynamic "preferred_during_scheduling_ignored_during_execution" {
                for_each = length(var.preferred_node_affinity) > 0 ? [1] : []
                content {
                  weight = 100
                  preference {
                    dynamic "match_expressions" {
                      for_each = var.preferred_node_affinity
                      content {
                        key      = match_expressions.key
                        operator = "In"
                        values   = match_expressions.value
                      }
                    }
                  }
                }
              }
            }
          }
        }

        # First start on a new volume: copy the old datadir in, so MySQL
        # never initialises an empty one (modules/volume-seed).
        dynamic "init_container" {
          for_each = local.seed ? [1] : []
          content {
            name    = "seed-data"
            image   = "busybox:stable-musl"
            command = ["sh", "-c", module.volume_seed.script]

            volume_mount {
              name       = "data"
              mount_path = "/new"
            }
            volume_mount {
              name       = "old-data"
              mount_path = "/old"
              read_only  = true
            }

            security_context {
              run_as_user = 0
            }

            resources {
              requests = module.volume_seed.resources.requests
              limits   = module.volume_seed.resources.limits
            }
          }
        }

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
          image = "mysql:8.4.11"
          args  = ["mysqld", "--init-file=/etc/mysql-init/init.sql"]

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
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/mysql"
            sub_path   = local.data_sub_path
          }

          volume_mount {
            name       = "root-init"
            mount_path = "/etc/mysql-init"
            read_only  = true
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
          name = "root-init"
          secret {
            secret_name  = kubernetes_secret_v1.mysql_root_init["enabled"].metadata[0].name
            default_mode = "0444"
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = local.csi_storage ? kubernetes_persistent_volume_claim_v1.mysql_data["enabled"].metadata[0].name : kubernetes_persistent_volume_claim_v1.mysql["enabled"].metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = local.seed ? [1] : []
          # The old volume (kept while seeding), through its claim: Pod
          # Security `baseline` forbids hostPath volumes in a pod spec.
          content {
            name = "old-data"
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.mysql["enabled"].metadata[0].name
              read_only  = true
            }
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
