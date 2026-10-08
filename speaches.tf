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
  # Shell image for the ownership fix and the voice preload Job.
  speaches_busybox_image = "busybox:1.36@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662"

  speaches_python_hooks_dir = "/opt/speaches-hooks"
  speaches_sitecustomize    = file("${path.module}/scripts/speaches/sitecustomize.py")

  # Whole cores in cpu_limit ("2", "1.5" or "1500m"), rounded up.
  speaches_cpu_limit_cores = ceil(
    endswith(local.speaches.cpu_limit, "m")
    ? tonumber(trimsuffix(local.speaches.cpu_limit, "m")) / 1000
    : tonumber(local.speaches.cpu_limit)
  )
  speaches_onnx_threads = (
    tonumber(local.speaches.onnx_threads) > 0
    ? tonumber(local.speaches.onnx_threads)
    : local.speaches_cpu_limit_cores
  )
}

# speaches builds its Piper and Kokoro ONNX sessions with no session options,
# and has no setting for them, so ONNX Runtime sizes its thread pool by the
# node's cores instead of the pod's CPU limit. Rather than fork the image,
# this sitecustomize.py is put on PYTHONPATH, where Python imports it at
# interpreter start; it fills in the thread count from ONNX_SESSION_THREADS.
resource "kubernetes_config_map_v1" "speaches_python_hooks" {
  for_each = local.speaches_instances

  metadata {
    name      = "speaches-python-hooks"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "speaches"
    })
  }

  data = {
    "sitecustomize.py" = local.speaches_sitecustomize
  }
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

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9]+$", tostring(local.speaches.onnx_threads)))
      error_message = "services.speaches.onnx_threads must be a whole number of threads; 0 follows cpu_limit."
    }
  }

  metadata {
    name      = "speaches"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "speaches"
    })
  }

  spec {
    replicas = 1

    # A rolling update starts the new pod next to the old one, and a second
    # memory_limit-sized pod does not fit the platform namespace quota: the
    # rollout stalls on FailedCreate while the old pod keeps serving.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { "app.kubernetes.io/name" = "speaches" }
    }

    template {
      metadata {
        labels = merge(module.platform_label.tags, {
          "app.kubernetes.io/name"      = "speaches"
          "app.kubernetes.io/component" = "speaches"
        })
        annotations = {
          # A ConfigMap update alone does not restart the pod, and Python
          # reads the hook only at start.
          "checksum/sitecustomize-py" = sha256(local.speaches_sitecustomize)
        }
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
          image   = local.speaches_busybox_image
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

          volume_mount {
            name       = "python-hooks"
            mount_path = local.speaches_python_hooks_dir
            read_only  = true
          }

          # Despite the name, Speaches applies this idle-unload TTL to every
          # model kind, Piper and Kokoro included.
          env {
            name  = "WHISPER__TTL"
            value = tostring(local.speaches.model_ttl_seconds)
          }

          # The upstream image sets no PYTHONPATH of its own to keep.
          env {
            name  = "PYTHONPATH"
            value = local.speaches_python_hooks_dir
          }

          # Read by sitecustomize.py.
          env {
            name  = "ONNX_SESSION_THREADS"
            value = tostring(local.speaches_onnx_threads)
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

        volume {
          name = "python-hooks"
          config_map {
            name = kubernetes_config_map_v1.speaches_python_hooks["enabled"].metadata[0].name
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

# ── Piper voice preload ───────────────────────────────────────────────────────
#
# One-shot Job that downloads every voice in `services.speaches.piper_voices`
# into the model cache and synthesises one short clip with each, so a voice
# the registry does not carry (or one that downloads but cannot speak) fails
# the apply rather than a caller's first turn. Runs against the live Service,
# like the Ollama model-pull Job. Speaches answers 200 for a fresh download
# and 201 for a cached one; both count as success.
#
# A Piper voice name `<lang>_<REGION>-<name>-<quality>` maps to the Speaches
# model `speaches-ai/piper-<voice name>` speaking voice `<name>`.

locals {
  speaches_piper_voices_instances = local.speaches.enabled && length(local.speaches.piper_voices) > 0 ? toset(["enabled"]) : toset([])
}

resource "kubernetes_job_v1" "speaches_piper_voices" {
  for_each = local.speaches_piper_voices_instances

  depends_on = [kubernetes_deployment_v1.speaches]

  lifecycle {
    precondition {
      condition     = alltrue([for v in local.speaches.piper_voices : can(regex("^[a-z]{2,3}_[A-Z]{2}-[a-z0-9_]+-(x_low|low|medium|high)$", v))])
      error_message = "services.speaches.piper_voices entries must be Piper voice names like en_US-amy-medium (<lang>_<REGION>-<name>-<quality>)."
    }
  }

  metadata {
    # Job specs are immutable; the hash suffix gives every voice-list change
    # a fresh Job instead of a `field is immutable` error.
    name      = "speaches-piper-voices-${substr(sha1(join(",", local.speaches.piper_voices)), 0, 10)}"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "speaches-piper-voices"
    })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(module.platform_label.tags, {
          "app.kubernetes.io/component" = "speaches-piper-voices"
        })
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "preload"
          image = local.speaches_busybox_image

          env {
            name  = "SPEACHES_URL"
            value = "http://${kubernetes_service_v1.speaches["enabled"].metadata[0].name}.${kubernetes_namespace_v1.platform.metadata[0].name}.svc.cluster.local:${kubernetes_service_v1.speaches["enabled"].spec[0].port[0].port}"
          }

          env {
            name  = "PIPER_VOICES"
            value = join(" ", local.speaches.piper_voices)
          }

          command = ["sh", "-c", <<-EOT
            set -eu
            for v in $PIPER_VOICES; do
              model="speaches-ai/piper-$v"
              name=$(echo "$v" | cut -d- -f2)
              echo "download $model"
              wget -q -O - --post-data '' "$SPEACHES_URL/v1/models/$model"
              echo
              # Some voices map characters straight to phonemes and skip any
              # character outside their script, so a Latin word comes back
              # as a near-empty clip from a Cyrillic voice.
              case "$v" in
                be_*|bg_*|kk_*|mk_*|ru_*|sr_*|uk_*) text="мама" ;;
                *) text="mama" ;;
              esac
              echo "synthesise $model voice $name"
              wget -q -O /tmp/clip.wav --header 'Content-Type: application/json' \
                --post-data "{\"model\":\"$model\",\"voice\":\"$name\",\"input\":\"$text\",\"response_format\":\"wav\"}" \
                "$SPEACHES_URL/v1/audio/speech"
              # A two-syllable word comes back as 9+ KB even from a 16 kHz
              # voice; a voice that skipped every character returns ~5 KB of
              # near-silence.
              if [ "$(head -c 4 /tmp/clip.wav)" != "RIFF" ] || [ "$(wc -c < /tmp/clip.wav)" -lt 8000 ]; then
                echo "$model returned no audible clip for '$text'" >&2
                exit 1
              fi
              echo "ok $model ($(wc -c < /tmp/clip.wav) bytes)"
            done
          EOT
          ]

          resources {
            requests = { cpu = "20m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "64Mi" }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    # A Piper voice is ~60 MB; the first synthesis also loads it.
    create = "15m"
  }
}
