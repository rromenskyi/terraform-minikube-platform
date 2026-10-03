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

  # Keys services.whisper.gpu may carry; anything else is a typo the
  # precondition below rejects rather than silently dropping (a misspelled
  # vulkan_device_id would otherwise lose the device pin).
  whisper_gpu_keys = ["device_path", "device_type", "privileged", "supplemental_groups", "vulkan_device_id", "env"]

  # Always an object so the deployment body never dereferences null; the
  # preconditions below reject a missing or malformed `gpu` block.
  whisper_gpu = {
    device_path         = try(local.whisper.gpu.device_path, "")
    device_type         = try(local.whisper.gpu.device_type, "CharDevice")
    privileged          = try(local.whisper.gpu.privileged, true)
    supplemental_groups = try(local.whisper.gpu.supplemental_groups, [])
    vulkan_device_id    = try(local.whisper.gpu.vulkan_device_id, "")
    env                 = try(local.whisper.gpu.env, {})
  }

  whisper_port        = 8080
  whisper_health_path = "/health"
  whisper_model_dir   = "/models"
  # The file name follows the URL, so overriding the model is one URL plus
  # its checksum.
  whisper_model_path = "${local.whisper_model_dir}/${basename(local.whisper.model_url)}"
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
        path = "${var.host_volume_path}/${local.whisper.namespace}/models"
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
      condition     = length(setsubtract(try(keys(local.whisper.gpu), []), local.whisper_gpu_keys)) == 0
      error_message = "services.whisper.gpu has unknown keys; allowed: device_path, device_type, privileged, supplemental_groups, vulkan_device_id, env."
    }
    precondition {
      condition     = !local.whisper_gpu.privileged || local.whisper_gpu.vulkan_device_id != ""
      error_message = "services.whisper.gpu.vulkan_device_id is required when privileged is true: a privileged pod sees every GPU on the host, and without the pin whisper may decode on the wrong one."
    }
    precondition {
      condition     = length(local.whisper.node_selector) > 0
      error_message = "services.whisper.node_selector must pin the pod to the node that owns gpu.device_path (the same selector as services.ollama)."
    }
    precondition {
      condition     = can(regex("^[0-9a-fA-F]{64}$", local.whisper.model_sha256))
      error_message = "services.whisper.model_sha256 must be the model file's 64-character hex sha256."
    }
    precondition {
      condition     = can(regex("^([0-9a-fA-F]{4}:[0-9a-fA-F]{4})?$", local.whisper_gpu.vulkan_device_id))
      error_message = "services.whisper.gpu.vulkan_device_id must be a PCI vendor:device hex pair (e.g. 8086:e212), or empty for an unprivileged pod that sees only its device."
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
        node_selector = local.whisper.node_selector

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
            "--port", tostring(local.whisper_port),
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

          # Mesa keeps compiled shaders here; without a writable cache every
          # start recompiles them on the first requests.
          env {
            name  = "XDG_CACHE_HOME"
            value = "/cache"
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
            run_as_non_root            = true
            run_as_user                = 1000
            run_as_group               = 1000
            read_only_root_filesystem  = true

            capabilities {
              drop = local.whisper_gpu.privileged ? [] : ["ALL"]
            }
          }

          port {
            name           = "http"
            container_port = local.whisper_port
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

          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }

          resources {
            requests = { cpu = local.whisper.cpu_request, memory = local.whisper.memory_request }
            limits   = { cpu = local.whisper.cpu_limit, memory = local.whisper.memory_limit }
          }

          # /health answers 503 until the model is loaded and does not take
          # the decode lock, so a long decode does not fail the probes.
          startup_probe {
            http_get {
              path = local.whisper_health_path
              port = local.whisper_port
            }
            period_seconds    = 5
            failure_threshold = 60
          }

          readiness_probe {
            http_get {
              path = local.whisper_health_path
              port = local.whisper_port
            }
            period_seconds  = 10
            timeout_seconds = 5
          }

          liveness_probe {
            http_get {
              path = local.whisper_health_path
              port = local.whisper_port
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
          name = "cache"
          empty_dir {}
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
      port        = local.whisper_port
      target_port = local.whisper_port
    }
  }
}
