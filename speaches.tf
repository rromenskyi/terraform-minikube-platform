# Speaches — self-hosted OpenAI-compatible STT/TTS server
# (github.com/speaches-ai/speaches, ex faster-whisper-server). Runs the
# upstream image directly (no custom build, no Helm chart needed for a
# single-container service). CPU-only: upstream only ships CPU/CUDA
# variants, no Intel GPU/Vulkan backend — doesn't compete with Ollama for
# the GPU. Exposes the standard OpenAI-compatible endpoints
# (/v1/audio/transcriptions, /v1/audio/speech, /v1/models) so it can be
# wired into AirLLM (or anything else in-cluster) as a provider target the
# same way any other OpenAI-compatible upstream is.
#
# Internal-only by default: no hostname/IngressRoute. Add one later the
# same way airllm.tf does if a public/testing route is ever needed.

locals {
  speaches           = local.platform.services.speaches
  speaches_instances = local.speaches.enabled ? toset(["enabled"]) : toset([])
}

resource "kubernetes_persistent_volume_v1" "speaches_model_cache" {
  for_each = local.speaches_instances

  metadata {
    name   = "platform-speaches-model-cache"
    labels = module.platform_label.tags
  }

  spec {
    capacity                         = { storage = local.speaches.storage_size }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.host_volume_path}/${local.speaches.namespace}/speaches/hf-hub-cache"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "speaches_model_cache" {
  for_each = local.speaches_instances

  metadata {
    name      = "speaches-model-cache"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = module.platform_label.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    resources {
      requests = { storage = local.speaches.storage_size }
    }
    volume_name = kubernetes_persistent_volume_v1.speaches_model_cache["enabled"].metadata[0].name
  }
}

resource "kubernetes_deployment_v1" "speaches" {
  for_each = local.speaches_instances

  metadata {
    name      = "speaches"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "speaches"
    })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = "speaches" }
    }

    template {
      metadata {
        labels = merge(module.platform_label.tags, {
          "app.kubernetes.io/name"      = "speaches"
          "app.kubernetes.io/component" = "speaches"
        })
      }

      spec {
        node_selector = local.speaches.node_selector

        # The image runs as uid 1000 (ubuntu). Without fsGroup the
        # model-cache PVC lands root-owned (kubelet creates the hostPath
        # dir as root before the pod's first mount) and every model
        # download fails with PermissionError. fsGroup matches the image's ubuntu gid
        # exactly so kubelet chowns the volume's group ownership on mount
        # going forward, but confirmed live that it does NOT retroactively
        # fix a hostPath volume's pre-existing root-owned root dir (group
        # stayed "root", not "1000", after the fsGroup change alone) — the
        # init container below is the handoff's own documented fallback,
        # not a hypothetical.
        security_context {
          fs_group = 1000
        }

        init_container {
          name    = "fix-model-cache-ownership"
          image   = "busybox:1.36"
          command = ["chown", "-R", "1000:1000", "/home/ubuntu/.cache/huggingface/hub"]

          volume_mount {
            name       = "model-cache"
            mount_path = "/home/ubuntu/.cache/huggingface/hub"
          }

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "64Mi" }
          }

          security_context {
            run_as_user  = 0
            run_as_group = 0
          }
        }

        container {
          name              = "speaches"
          image             = local.speaches.image
          image_pull_policy = "IfNotPresent"

          port {
            name           = "http"
            container_port = 8000
          }

          volume_mount {
            name       = "model-cache"
            mount_path = "/home/ubuntu/.cache/huggingface/hub"
          }

          resources {
            requests = { cpu = local.speaches.cpu_request, memory = local.speaches.memory_request }
            limits   = { cpu = local.speaches.cpu_limit, memory = local.speaches.memory_limit }
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
        }

        volume {
          name = "model-cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.speaches_model_cache["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "speaches" {
  for_each = local.speaches_instances

  metadata {
    name      = "speaches"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = module.platform_label.tags
  }

  spec {
    selector = { "app.kubernetes.io/name" = "speaches" }

    port {
      name        = "http"
      port        = 8000
      target_port = 8000
    }
  }
}
