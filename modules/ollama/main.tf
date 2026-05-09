terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}


# `privileged` defaults to true to preserve the prior shape; this is
# a sledgehammer that grants every device cgroup, every capability
# and bypasses AppArmor. With a CharDevice volume on a modern
# k3s/containerd + cgroup v2 host, kubelet adds the per-device
# cgroup allow rule by itself, so unprivileged Vulkan inference is
# usually possible. Operators can opt out via `privileged: false`
# to lock the platform-namespace Ollama down (and as a side effect
# make `runc` stop mknod-ing every host device into the pod's
# tmpfs /dev — Mesa Anv then enumerates ONLY the projected device
# instead of probing every renderD* node it finds).


locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
  # Reused as the iteration list for every GPU-only `dynamic` block —
  # one entry when GPU offload is configured, zero otherwise. Keeps the
  # `for_each` lines below short and identical so the gating intent is
  # obvious at a glance.
  gpu_iter = var.gpu == null ? [] : [var.gpu]
  # Model-pull Job is separately gated — skipped when the module is off
  # OR when the operator explicitly supplies an empty models list.
  pull_instances = var.enabled && length(var.models) > 0 ? toset(["enabled"]) : toset([])
}

# ── Persistent storage (models cache) ─────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "ollama" {
  for_each = local.instances

  metadata {
    name = "platform-ollama-data"
  }

  spec {
    capacity = {
      storage = var.storage_size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.volume_base_path}/${var.namespace}/ollama"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "ollama" {
  for_each = local.instances

  metadata {
    name      = "ollama-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.ollama["enabled"].metadata[0].name

    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# ── StatefulSet ───────────────────────────────────────────────────────────────

resource "kubernetes_stateful_set_v1" "ollama" {
  for_each = local.instances

  metadata {
    name      = "ollama"
    namespace = var.namespace
    labels    = { app = "ollama" }
  }

  spec {
    replicas     = 1
    service_name = "ollama"

    selector {
      match_labels = { app = "ollama" }
    }

    template {
      metadata {
        labels = { app = "ollama" }
      }

      spec {
        # Pod placement primitives. All default empty so existing
        # deployments are unaffected. Set `var.node_selector =
        # { gpu = "intel" }` to pin the pod onto the node that owns
        # the device referenced in `var.gpu.device_path`.
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

        dynamic "affinity" {
          for_each = length(keys(var.affinity)) > 0 ? [var.affinity] : []
          content {
            dynamic "node_affinity" {
              for_each = try(affinity.value.node_affinity, null) != null ? [affinity.value.node_affinity] : []
              content {
                dynamic "required_during_scheduling_ignored_during_execution" {
                  for_each = try(node_affinity.value.required_during_scheduling_ignored_during_execution, null) != null ? [node_affinity.value.required_during_scheduling_ignored_during_execution] : []
                  content {
                    dynamic "node_selector_term" {
                      for_each = try(required_during_scheduling_ignored_during_execution.value.node_selector_terms, [])
                      content {
                        dynamic "match_expressions" {
                          for_each = try(node_selector_term.value.match_expressions, [])
                          content {
                            key      = match_expressions.value.key
                            operator = match_expressions.value.operator
                            values   = try(match_expressions.value.values, null)
                          }
                        }
                      }
                    }
                  }
                }
                dynamic "preferred_during_scheduling_ignored_during_execution" {
                  for_each = try(node_affinity.value.preferred_during_scheduling_ignored_during_execution, [])
                  content {
                    weight = preferred_during_scheduling_ignored_during_execution.value.weight
                    preference {
                      dynamic "match_expressions" {
                        for_each = try(preferred_during_scheduling_ignored_during_execution.value.preference.match_expressions, [])
                        content {
                          key      = match_expressions.value.key
                          operator = match_expressions.value.operator
                          values   = try(match_expressions.value.values, null)
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        # Pod-level securityContext only emitted when GPU offload is
        # configured. `run_as_non_root = false` lets the root-running
        # Ollama image through PSS-restricted namespaces;
        # `supplemental_groups` is operator-supplied (typically host
        # `video` + `render` GIDs so the device files projected from
        # `var.gpu.device_path` are accessible from inside the pod).
        dynamic "security_context" {
          for_each = local.gpu_iter
          content {
            run_as_non_root     = false
            supplemental_groups = security_context.value.supplemental_groups
          }
        }

        container {
          name = "ollama"
          # GPU-capable image from `var.gpu.image` when configured;
          # CPU-only `ollama/ollama:latest` otherwise.
          image   = var.gpu == null ? "ollama/ollama:latest" : var.gpu.image
          command = var.gpu == null ? null : ["ollama", "serve"]

          # Container-level privileged context only emitted when GPU
          # offload is configured. `privileged` is operator-supplied
          # (default true). `run_as_non_root = false` always — the
          # upstream Ollama image runs as root regardless of privileged
          # status, and `read_only_root_filesystem = false` lets it
          # write its scratch files. Without GPU the pod keeps the
          # upstream restricted defaults.
          dynamic "security_context" {
            for_each = local.gpu_iter
            content {
              privileged                 = security_context.value.privileged
              allow_privilege_escalation = security_context.value.privileged
              read_only_root_filesystem  = false
              run_as_non_root            = false
            }
          }

          port {
            container_port = 11434
          }

          # `OLLAMA_HOST=0.0.0.0` exposes the API on all interfaces inside
          # the pod — the Ollama default binds loopback only, which would
          # make the ClusterIP Service below a dead end.
          env {
            name  = "OLLAMA_HOST"
            value = "0.0.0.0"
          }

          # Default context for model loads. See `var.context_length`
          # docstring for the silent-truncation rationale — short
          # version: 4096 chops our tool catalog, 8192 fits it.
          env {
            name  = "OLLAMA_CONTEXT_LENGTH"
            value = tostring(var.context_length)
          }

          # Keep loaded models resident so the prefix cache (tool
          # catalog + system prompt) stays warm across chat sessions.
          # Default 24h in `var.keep_alive` — see its docstring for
          # the TTFT math that motivates this.
          env {
            name  = "OLLAMA_KEEP_ALIVE"
            value = var.keep_alive
          }

          # GPU-specific env vars (Vulkan/CUDA/HIP toggles, Mesa device
          # selection, debug verbosity, …) injected verbatim from
          # `var.gpu.env`. Empty when GPU is unset.
          dynamic "env" {
            for_each = var.gpu == null ? {} : var.gpu.env
            content {
              name  = env.key
              value = env.value
            }
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
            mount_path = "/root/.ollama"
          }

          # Host GPU device path projected into the container at the
          # same path. Without this mount the GPU env vars are inert
          # and Ollama silently falls back to CPU.
          dynamic "volume_mount" {
            for_each = local.gpu_iter
            content {
              name       = "gpu-device"
              mount_path = volume_mount.value.device_path
            }
          }

          startup_probe {
            http_get {
              path = "/api/tags"
              port = 11434
            }
            period_seconds    = 5
            failure_threshold = 30
            timeout_seconds   = 3
          }

          liveness_probe {
            http_get {
              path = "/api/tags"
              port = 11434
            }
            period_seconds    = 30
            failure_threshold = 3
            timeout_seconds   = 5
          }

          readiness_probe {
            http_get {
              path = "/api/tags"
              port = 11434
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.ollama["enabled"].metadata[0].name
          }
        }

        # Host GPU device path projected into the pod. `device_type`
        # picks the kubelet hostPath type — `Directory` for the whole
        # /dev/dri (or /dev/nvidia) tree, `CharDevice` to expose only
        # a single device file (e.g. /dev/dri/renderD129) and hide the
        # rest. Matching `volume_mount` is on the container above. The
        # pod-level `supplemental_groups` grant access to whatever GIDs
        # own the device files on the host.
        dynamic "volume" {
          for_each = local.gpu_iter
          content {
            name = "gpu-device"
            host_path {
              path = volume.value.device_path
              type = volume.value.device_type
            }
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "ollama" {
  for_each = local.instances

  metadata {
    name      = "ollama"
    namespace = var.namespace
    labels    = { app = "ollama" }
  }

  spec {
    selector = { app = "ollama" }

    port {
      name        = "http"
      port        = 11434
      target_port = 11434
    }
  }
}

# ── Model pull Job ────────────────────────────────────────────────────────────
#
# One-shot Job that pre-pulls every model listed in `var.models` into the
# mounted cache. Runs against the live Service (not the PV) so the Job
# can live independently of the StatefulSet pod's lifecycle and the
# server holds the models in its in-memory registry.
#
# `ollama pull` is idempotent (digest-checked), so re-applies re-run the
# Job cheaply — nothing is downloaded if the model is already cached.
# The Job waits for completion, which means `terraform apply` blocks
# until models are on disk.

resource "kubernetes_job_v1" "pull_models" {
  for_each = local.pull_instances

  depends_on = [kubernetes_stateful_set_v1.ollama]

  metadata {
    # `-${sha1}` suffix forces a fresh Job on every models-list change —
    # Job specs are immutable, so the same name across applies would
    # otherwise produce `field is immutable` errors.
    name      = "ollama-pull-${substr(sha1(join(",", var.models)), 0, 10)}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "ollama-pull"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = { job = "ollama-pull" }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "pull"
          image = "ollama/ollama:latest"

          env {
            name  = "OLLAMA_HOST"
            value = "http://${kubernetes_service_v1.ollama["enabled"].metadata[0].name}.${var.namespace}.svc.cluster.local:11434"
          }

          # The pull Job talks to the remote Ollama Service — no local
          # inference, no model held in this pod's RAM. What it does need
          # is enough headroom for the HTTP client + the `ollama` binary's
          # own working set while streaming a ~5Gi tarball off the network.
          # Requests stay tiny so the Job schedules anywhere; the 1Gi limit
          # is purely a safety cap. Explicit limits are required when the
          # namespace ResourceQuota demands them on every pod.
          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }

          command = ["sh", "-c", join(" && ", [
            for m in var.models : "ollama pull ${m}"
          ])]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    # Model downloads over residential ISP can be slow. A 9–10 GiB model
    # like `gemma4:e4b` or `qwen2.5:14b` is ~8–10 min alone on a
    # ~20 MB/s link; a 4–6 model list pushes the total into the tens of
    # minutes even with layer sharing. The Job itself is idempotent
    # (`ollama pull` is a no-op on already-cached models), so an ample
    # terraform-side timeout is cheap — reruns are fast.
    create = "60m"
  }
}

