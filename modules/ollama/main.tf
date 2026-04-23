terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

variable "enabled" {
  description = "Deploy the Ollama StatefulSet + model-pull Job. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the Ollama StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path for the hostPath PersistentVolume. Models cache lands at <volume_base_path>/<namespace>/ollama/."
  type        = string
  default     = "/data/vol"
}

variable "storage_size" {
  description = "Capacity of the models cache volume. Budget ~2Gi per 1B parameters; a single 7B model is ~4–8Gi, a 70B model is 40Gi+."
  type        = string
  default     = "50Gi"
}

variable "memory_request" {
  description = "Memory request. Inference peaks near the model size — `deepseek-r1:1.5b` fits in 2Gi, 7B models want 6Gi+."
  type        = string
  default     = "4Gi"
}

variable "memory_limit" {
  description = "Memory limit. Hitting it kills the pod and evicts every cached model from RAM. 16Gi comfortably fits a 7B–13B model loaded at once."
  type        = string
  default     = "16Gi"
}

variable "cpu_request" {
  description = "CPU request. Idle Ollama barely uses any CPU; 200m covers the HTTP server + light background work."
  type        = string
  default     = "200m"
}

variable "cpu_limit" {
  description = "CPU limit. Inference saturates every core it can get, so keep this generous — the pod lives alone in the `platform` namespace on a single node."
  type        = string
  default     = "10"
}

variable "models" {
  description = "Models to pull after the server is ready. The one-shot Job is idempotent — `ollama pull` is a no-op when the model is already cached — so re-applies are cheap. Leave empty to skip the pull step entirely."
  type        = list(string)
  default     = ["deepseek-r1:1.5b"]
}

variable "context_length" {
  description = <<-EOT
    Default context window Ollama uses when loading any model.
    Ollama's built-in default is 4096 tokens, which silently
    truncates prompts that exceed it — observed 2026-04-21 when
    the mcp-weather-simple tool catalog (~4500 tokens: 22 tools
    × ~150 desc + schemas + instructions preamble) was chopped
    from the tail, making later tool schemas invisible to the
    model and chat completions returning `tool_calls: []` with
    200 OK and no error anywhere. 8192 covers the current
    catalog with headroom; qwen2.5 supports 128K natively so
    there's lots of room to bump further if new tools push us
    past ~6K. One-line tell in Ollama logs when truncation
    fires: `truncating input prompt limit=4096 prompt=<N> ...`.
  EOT
  type        = number
  default     = 8192
}

variable "keep_alive" {
  description = <<-EOT
    How long Ollama keeps a model resident in RAM after its last
    request. Accepts Go duration strings (`5m`, `24h`) or special
    values: `-1` = never unload, `0` = unload immediately.
    Ollama's built-in default is `5m` — a model unloads after 5
    minutes idle, so the next request pays both the model-load
    cost (~3-5 s for qwen3.5:9b) AND a cold prefill of the entire
    system prompt + tool catalog (~1.3K tokens in the sibling
    mcp-weather-simple's `fat_tools_lean` = ~8-13 s on i7 CPU).
    Keeping the model resident lets Ollama's automatic prefix-cache
    stay warm across sessions: the first message of any new
    conversation skips the catalog prefill. 24h is the sweet spot
    for single-operator workloads — hot through the whole day,
    quietly drops the model overnight so the kernel can reclaim
    the ~6.6 GB that qwen3.5:9b Q4_K_M pins.
  EOT
  type        = string
  default     = "24h"
}

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
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
        container {
          name  = "ollama"
          image = "ollama/ollama:latest"

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

# ── Outputs ───────────────────────────────────────────────────────────────────

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Ollama is deployed, or null if disabled."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.ollama : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "Ollama in-cluster hostname, or null if disabled."
}

output "url" {
  value       = one([for s in kubernetes_service_v1.ollama : "http://${s.metadata[0].name}.${var.namespace}.svc.cluster.local:11434"])
  description = "Ollama in-cluster URL — drop straight into OLLAMA_HOST. Null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.ollama : s.metadata[0].name])
  description = "Ollama Service name, or null if disabled."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.ollama : s.spec[0].port[0].port])
  description = "Ollama Service port, or null if disabled."
}

output "models" {
  value       = var.enabled ? var.models : []
  description = "Models pre-pulled by this module (empty list if disabled)."
}
