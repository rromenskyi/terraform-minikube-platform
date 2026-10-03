# whisper.cpp server on a Vulkan GPU — an OpenAI-shaped transcription route
# (`POST /v1/audio/transcriptions`, multipart `file` + `model`, `language`,
# `prompt`, `response_format`) for a Whisper model that is too slow on the
# CPU. Speaches covers CPU recognition; this covers the GPU, which upstream
# Speaches cannot use on cards without CUDA.
#
# The image is operator-built from images/whisper-server-vulkan (no upstream
# image carries a Mesa for every card), and the pod shares the GPU with
# Ollama: same node selector, same device-access shape as
# `services.ollama.gpu`. Sizing the two to fit one card's VRAM together is
# the operator's job — see docs/runbooks/whisper-server-vulkan-image.md.
#
# whisper-server decodes one request at a time (a single model context
# behind a mutex); concurrent requests queue inside the pod. A gateway in
# front should cap the provider's concurrency at 1 so overflow moves to the
# next tier instead of queueing behind another call.
#
# Internal-only: no hostname/IngressRoute.

locals {
  whisper           = local.platform.services.whisper
  whisper_instances = local.whisper.enabled ? toset(["enabled"]) : toset([])

  # Always an object so the deployment body never dereferences null; the
  # precondition below rejects a missing `gpu` block with a clear message.
  whisper_gpu = {
    device_path         = try(local.whisper.gpu.device_path, "")
    device_type         = try(local.whisper.gpu.device_type, "CharDevice")
    privileged          = try(local.whisper.gpu.privileged, true)
    supplemental_groups = try(local.whisper.gpu.supplemental_groups, [])
    vulkan_device_id    = try(local.whisper.gpu.vulkan_device_id, "")
    env                 = try(local.whisper.gpu.env, {})
  }

  whisper_model_dir  = "/models"
  whisper_model_path = "${local.whisper_model_dir}/${local.whisper.model_file}"
}

resource "kubernetes_persistent_volume_v1" "whisper_models" {
  for_each = local.whisper_instances

  metadata {
    name   = "platform-whisper-models"
    labels = module.platform_label.tags
  }

  spec {
    capacity                         = { storage = local.whisper.storage_size }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.host_volume_path}/${local.whisper.namespace}/whisper/models"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "whisper_models" {
  for_each = local.whisper_instances

  metadata {
    name      = "whisper-models"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = module.platform_label.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    resources {
      requests = { storage = local.whisper.storage_size }
    }
    volume_name = kubernetes_persistent_volume_v1.whisper_models["enabled"].metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "whisper" {
  for_each = local.whisper_instances

  lifecycle {
    precondition {
      condition     = local.whisper.image != ""
      error_message = "services.whisper.image must be set when whisper is enabled (build images/whisper-server-vulkan; see docs/runbooks/whisper-server-vulkan-image.md)."
    }
    precondition {
      condition     = local.whisper.gpu != null && local.whisper_gpu.device_path != ""
      error_message = "services.whisper.gpu with a device_path must be set when whisper is enabled: the service exists to decode on a GPU (device_path, supplemental_groups, vulkan_device_id)."
    }
    precondition {
      condition     = can(regex("^[0-9a-fA-F]{64}$", local.whisper.model_sha256))
      error_message = "services.whisper.model_sha256 must be the model file's 64-character hex sha256."
    }
    precondition {
      condition     = can(regex("^([0-9a-fA-F]{4}:[0-9a-fA-F]{4})?$", local.whisper_gpu.vulkan_device_id))
      error_message = "services.whisper.gpu.vulkan_device_id must be a PCI vendor:device hex pair (e.g. 8086:e212) or empty."
    }
    precondition {
      condition     = contains(["CharDevice", "Directory"], local.whisper_gpu.device_type)
      error_message = "services.whisper.gpu.device_type must be CharDevice or Directory."
    }
  }

  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "whisper"
    })
  }

  spec {
    replicas = 1

    # A rolling update would start the new pod while the old one still holds
    # its copy of the model in VRAM — on a card shared with Ollama that is
    # exactly the moment the card runs out.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { "app.kubernetes.io/name" = "whisper" }
    }

    template {
      metadata {
        labels = merge(module.platform_label.tags, {
          "app.kubernetes.io/name"      = "whisper"
          "app.kubernetes.io/component" = "whisper"
        })
      }

      spec {
        node_selector = length(local.whisper.node_selector) > 0 ? local.whisper.node_selector : null

        security_context {
          supplemental_groups = local.whisper_gpu.supplemental_groups
        }

        # Runs as root: the hostPath model directory is created root-owned by
        # kubelet. The server only reads the file, so it can stay uid 1000.
        init_container {
          name    = "fetch-model"
          image   = local.whisper.image
          command = ["/usr/local/bin/whisper-fetch-model", local.whisper.model_url, local.whisper_model_path, local.whisper.model_sha256]

          volume_mount {
            name       = "models"
            mount_path = local.whisper_model_dir
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          security_context {
            run_as_user  = 0
            run_as_group = 0
          }
        }

        container {
          name              = "whisper"
          image             = local.whisper.image
          image_pull_policy = "IfNotPresent"

          args = concat([
            "--host", "0.0.0.0",
            "--port", "8080",
            "--model", local.whisper_model_path,
            "--inference-path", "/v1/audio/transcriptions",
            # Detect per request unless the caller sends `language`.
            "--language", "auto",
            "--threads", tostring(local.whisper.threads),
          ], local.whisper.extra_args)

          env {
            name  = "WHISPER_VULKAN_DEVICE_ID"
            value = local.whisper_gpu.vulkan_device_id
          }

          env {
            name  = "WHISPER_REQUIRE_GPU"
            value = "1"
          }

          dynamic "env" {
            for_each = local.whisper_gpu.env
            content {
              name  = env.key
              value = env.value
            }
          }

          # Privileged mirrors services.ollama.gpu: on some containerd setups
          # kubelet grants no device-cgroup rule for a CharDevice hostPath and
          # Mesa then fails to open the render node. Without privileged, the
          # pod keeps a locked-down context.
          security_context {
            privileged                 = local.whisper_gpu.privileged
            allow_privilege_escalation = local.whisper_gpu.privileged
            run_as_user                = 1000
            run_as_group               = 1000
          }

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "models"
            mount_path = local.whisper_model_dir
            read_only  = true
          }

          volume_mount {
            name       = "gpu"
            mount_path = local.whisper_gpu.device_path
          }

          resources {
            requests = { cpu = local.whisper.cpu_request, memory = local.whisper.memory_request }
            limits   = { cpu = local.whisper.cpu_limit, memory = local.whisper.memory_limit }
          }

          # /health answers 503 until the model is loaded and does not take
          # the decode lock, so a long decode does not fail the probes.
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 60
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds  = 10
            timeout_seconds = 5
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds    = 30
            timeout_seconds   = 5
            failure_threshold = 3
          }
        }

        volume {
          name = "models"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.whisper_models["enabled"].metadata[0].name
          }
        }

        volume {
          name = "gpu"
          host_path {
            path = local.whisper_gpu.device_path
            type = local.whisper_gpu.device_type
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "whisper" {
  for_each = local.whisper_instances

  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = module.platform_label.tags
  }

  spec {
    selector = { "app.kubernetes.io/name" = "whisper" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
