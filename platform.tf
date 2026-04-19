# Root-level `platform` namespace — home for every shared platform
# service (MySQL, Redis, Ollama, …). Owned here (not inside any single
# module) because none of those modules logically owns the namespace:
# they're peers that happen to land next to each other.
resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = "platform"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = "platform"
    }
  }
}

# Platform-wide resource budget. Sized in config/platform.yaml under
# `namespace_limits` — Ollama alone can burn 10 CPU during inference
# and wants 16Gi RAM for larger models, so this namespace lives in a
# different tier than the per-tenant 2 CPU / 4Gi default.
resource "kubernetes_resource_quota_v1" "platform" {
  metadata {
    name      = "platform-budget"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    hard = {
      "requests.cpu"    = try(local.namespace_limits.platform.cpu, local.default_limits.cpu)
      "requests.memory" = try(local.namespace_limits.platform.memory, local.default_limits.memory)
      "limits.cpu"      = try(local.namespace_limits.platform.cpu, local.default_limits.cpu)
      "limits.memory"   = try(local.namespace_limits.platform.memory, local.default_limits.memory)
      "pods"            = tostring(try(local.namespace_limits.platform.pods, local.default_limits.pods, 50))
    }
  }
}
