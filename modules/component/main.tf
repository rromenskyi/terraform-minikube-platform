terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

variable "name" {
  description = "Component name — used as Deployment/Service name and label selector"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into"
  type        = string
}

variable "image" {
  description = "Container image (e.g. nginx:alpine)"
  type        = string
}

variable "port" {
  description = "Container port exposed by the application"
  type        = number
}

variable "replicas" {
  description = "Desired number of pod replicas"
  type        = number
  default     = 2
}

variable "resources" {
  description = "CPU/memory requests and limits"
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { cpu = "200m", memory = "256Mi" }
  }
}

variable "health_path" {
  description = "HTTP path for liveness/readiness probes. Set to null to disable probes."
  type        = string
  default     = "/"
}

variable "storage" {
  description = "Persistent volumes to mount into the container"
  type = list(object({
    mount = string
    size  = string
  }))
  default = []
}

variable "db_secret_name" {
  description = "Name of the db-credentials Secret to expose as env vars. Null = no db."
  type        = string
  default     = null
}

variable "db_env_mapping" {
  description = "Map of env var name → secret key for DB credentials. When set, uses individual env vars instead of env_from."
  type        = map(string)
  default     = {}
}

variable "volume_base_path" {
  description = "Parent path used verbatim by hostPath PersistentVolumes for this component. Each volume lands at <volume_base_path>/<namespace>/<name>/<slug>/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol)."
  type        = string
  default     = "/data/vol"
}

variable "config_files" {
  description = "Map of file path → content to mount into the container via ConfigMap"
  type        = map(string)
  default     = {}
}

variable "security" {
  description = "Optional pod `securityContext` knobs. `run_as_user` pins the container UID; `fs_group` makes kubelet chown every hostPath volume to that GID at mount time — the latter is how a WordPress image (www-data, UID 33) writes to a host-owned directory without a separate init container."
  type = object({
    run_as_user = optional(number)
    fs_group    = optional(number)
  })
  default = {}
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  # Map slug → volume spec. Slug is the PV/PVC name suffix and k8s volume name.
  volumes = {
    for v in var.storage :
    replace(trimprefix(v.mount, "/"), "/", "-") => v
  }
}

# ── Persistent Volumes ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "this" {
  for_each = local.volumes

  metadata {
    name = "${var.namespace}-${var.name}-${each.key}"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = var.namespace
      "component"                    = var.name
    }
  }

  spec {
    capacity = {
      storage = each.value.size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        # Resolves to e.g.
        #   macOS minikube: /minikube-host/Shared/vol/{namespace}/{component}/{slug}/
        #   native k3s:     /data/vol/{namespace}/{component}/{slug}/
        path = "${var.volume_base_path}/${var.namespace}/${var.name}/${each.key}"
        type = "DirectoryOrCreate"
      }
    }
  }
}

# ── Persistent Volume Claims ──────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "this" {
  for_each = local.volumes

  metadata {
    name      = "${var.name}-${each.key}"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.this[each.key].metadata[0].name

    resources {
      requests = {
        storage = each.value.size
      }
    }
  }
}

# ── Config Files (ConfigMap) ──────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "files" {
  count = length(var.config_files) > 0 ? 1 : 0

  metadata {
    name      = "${var.name}-config"
    namespace = var.namespace
    labels    = { app = var.name }
  }

  data = {
    for path, content in var.config_files :
    replace(trimprefix(path, "/"), "/", "--") => content
  }
}

# ── Deployment ────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = var.name }
    }

    template {
      metadata {
        labels = { app = var.name }
      }

      spec {
        dynamic "security_context" {
          for_each = (
            try(var.security.run_as_user, null) != null
            || try(var.security.fs_group, null) != null
          ) ? [1] : []
          content {
            run_as_user = try(var.security.run_as_user, null)
            fs_group    = try(var.security.fs_group, null)
          }
        }

        # hostPath volumes ignore the pod-level `fsGroup` — the kubelet
        # refuses to recursively chown something on the host filesystem
        # it didn't create. Without this init container, a non-root main
        # container (e.g. WordPress's www-data, UID 33) fails on first
        # start with `mkdir: Permission denied` trying to seed
        # `/var/www/html/wp-content` from the image. Run a one-shot root
        # container that chowns every mounted volume to the configured
        # UID/GID, then the main container can read/write normally.
        dynamic "init_container" {
          for_each = (
            try(var.security.fs_group, null) != null
            && length(local.volumes) > 0
          ) ? [1] : []
          content {
            name  = "chown-volumes"
            image = "busybox:stable-musl"

            security_context {
              run_as_user = 0
            }

            # Minimal resources — the init container runs once per pod
            # start, for milliseconds, and only issues a chown. Explicit
            # values are required because tenant namespaces carry a
            # LimitRange that rejects any container missing them.
            resources {
              requests = { cpu = "10m", memory = "16Mi" }
              limits   = { cpu = "50m", memory = "32Mi" }
            }

            command = ["sh", "-c", join(" && ", [
              for k, v in local.volumes :
              "chown -R ${try(var.security.run_as_user, 0)}:${var.security.fs_group} ${v.mount}"
            ])]

            dynamic "volume_mount" {
              for_each = local.volumes
              content {
                name       = volume_mount.key
                mount_path = volume_mount.value.mount
              }
            }
          }
        }

        container {
          name  = var.name
          image = var.image

          port {
            container_port = var.port
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # DB credentials: mapped env vars (e.g. WORDPRESS_DB_HOST → secret key DB_HOST)
          dynamic "env" {
            for_each = var.db_secret_name != null && length(var.db_env_mapping) > 0 ? var.db_env_mapping : {}
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = var.db_secret_name
                  key  = env.value
                }
              }
            }
          }

          # DB credentials injected as-is from Secret (when no mapping provided)
          dynamic "env_from" {
            for_each = var.db_secret_name != null && length(var.db_env_mapping) == 0 ? [var.db_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # Health probes — disabled when health_path is null (e.g. WordPress setup flow)
          dynamic "liveness_probe" {
            for_each = var.health_path != null ? [1] : []
            content {
              http_get {
                path = var.health_path
                port = var.port
              }
              initial_delay_seconds = 10
              period_seconds        = 10
            }
          }

          dynamic "readiness_probe" {
            for_each = var.health_path != null ? [1] : []
            content {
              http_get {
                path = var.health_path
                port = var.port
              }
              initial_delay_seconds = 5
              period_seconds        = 5
            }
          }

          dynamic "volume_mount" {
            for_each = local.volumes
            content {
              name       = volume_mount.key
              mount_path = volume_mount.value.mount
            }
          }

          dynamic "volume_mount" {
            for_each = var.config_files
            content {
              name       = "config-files"
              mount_path = volume_mount.key
              sub_path   = replace(trimprefix(volume_mount.key, "/"), "/", "--")
              read_only  = true
            }
          }
        }

        dynamic "volume" {
          for_each = local.volumes
          content {
            name = volume.key
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.this[volume.key].metadata[0].name
            }
          }
        }

        dynamic "volume" {
          for_each = length(var.config_files) > 0 ? [1] : []
          content {
            name = "config-files"
            config_map {
              name = kubernetes_config_map_v1.files[0].metadata[0].name
            }
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }

  spec {
    selector = { app = var.name }

    port {
      port        = var.port
      target_port = var.port
    }
  }
}
