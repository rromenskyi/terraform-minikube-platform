# Cluster-internal BuildKit daemon for self-hosted runner image
# builds. Single shared `buildkitd` Pod exposes its gRPC API on
# `tcp://buildkitd.arc-buildkitd.svc.cluster.local:1234` —
# workflows on ARC-managed runners hit it via
# `docker buildx create --driver remote --use --bootstrap` +
# `docker buildx build`. Cache slabs live on a PVC so sequential
# builds reuse layers across runner pods (which are ephemeral).
#
# Why standalone vs `--driver kubernetes` (per-job buildkitd Pod):
# the kubernetes driver creates / destroys a buildkitd Pod per
# build, which (a) needs RBAC on the runner SA to manage Pods,
# (b) loses cache on every job teardown. Single shared daemon
# trades isolation between concurrent builds (one warm cache,
# possible cache poisoning if untrusted code runs in CI) for
# warm-cache build speed and zero RBAC delegation.
#
# Image: `moby/buildkit:<ver>-rootless`. Rootless mode runs as
# uid 1000, no `privileged: true` on the Pod, no host kernel
# capabilities. User-namespace remapping inside the container
# isolates the build; that's enough for our trust boundary
# (single-operator cluster, no untrusted PRs in our CI today).

locals {
  buildkitd_enabled   = local.platform.services.buildkitd.enabled
  buildkitd_namespace = "arc-buildkitd"
}

resource "kubernetes_namespace_v1" "buildkitd" {
  count = local.buildkitd_enabled ? 1 : 0

  metadata {
    name = local.buildkitd_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "buildkitd"
      # Rootless buildkit needs `restricted` PSA exemption for
      # `procMount: Unmasked` on the user-namespace setup. Use
      # `baseline` so the Pod's seccomp / unprivileged userns
      # capabilities aren't blocked at admission.
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "buildkitd_cache" {
  count = local.buildkitd_enabled ? 1 : 0

  metadata {
    name      = "buildkitd-cache"
    namespace = kubernetes_namespace_v1.buildkitd[0].metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = local.platform.services.buildkitd.cache_size
      }
    }
    storage_class_name = local.platform.services.buildkitd.storage_class != "" ? local.platform.services.buildkitd.storage_class : null
  }

  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "buildkitd" {
  count = local.buildkitd_enabled ? 1 : 0

  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.buildkitd[0].metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "buildkitd"
      "app.kubernetes.io/component" = "buildkitd"
    }
  }

  spec {
    # Single replica — one shared cache. Scaling out loses cache
    # locality (each replica's PVC is independent on RWO).
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "buildkitd"
      }
    }

    strategy {
      # Recreate (not RollingUpdate) because PVC is RWO — a new
      # replica can't attach while the old one holds the volume.
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "buildkitd"
        }
        annotations = {
          # Rootless buildkit needs the seccomp + apparmor
          # profiles relaxed for unprivileged-user-namespace
          # creation. `unconfined` is broad but not privileged.
          "container.apparmor.security.beta.kubernetes.io/buildkitd" = "unconfined"
        }
      }

      spec {
        node_selector = local.platform.services.buildkitd.node_selector

        dynamic "toleration" {
          for_each = local.platform.services.buildkitd.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          run_as_non_root = true
          seccomp_profile {
            type = "Unconfined"
          }
        }

        container {
          name  = "buildkitd"
          image = "moby/buildkit:${local.platform.services.buildkitd.image_tag}"

          args = [
            "--addr",
            "unix:///run/user/1000/buildkit/buildkitd.sock",
            "--addr",
            "tcp://0.0.0.0:1234",
            # OCI worker — standard, no `--oci-worker-no-process-sandbox`
            # so unprivileged user-namespace isolation kicks in
            # automatically.
            "--oci-worker-no-process-sandbox=false",
          ]

          port {
            container_port = 1234
            name           = "grpc"
            protocol       = "TCP"
          }

          security_context {
            run_as_user                = 1000
            run_as_group               = 1000
            run_as_non_root            = true
            allow_privilege_escalation = false
            seccomp_profile {
              type = "Unconfined"
            }
          }

          readiness_probe {
            exec {
              command = ["buildctl", "debug", "workers"]
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }

          volume_mount {
            name       = "cache"
            mount_path = "/home/user/.local/share/buildkit"
          }

          resources {
            requests = {
              cpu    = local.platform.services.buildkitd.cpu_request
              memory = local.platform.services.buildkitd.memory_request
            }
            limits = {
              cpu    = local.platform.services.buildkitd.cpu_limit
              memory = local.platform.services.buildkitd.memory_limit
            }
          }
        }

        volume {
          name = "cache"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.buildkitd_cache[0].metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "buildkitd" {
  count = local.buildkitd_enabled ? 1 : 0

  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.buildkitd[0].metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "buildkitd"
      "app.kubernetes.io/component" = "buildkitd"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "buildkitd"
    }

    port {
      name        = "grpc"
      port        = 1234
      target_port = 1234
      protocol    = "TCP"
    }
  }
}

output "buildkitd_endpoint" {
  description = "In-cluster BuildKit gRPC endpoint for `docker buildx create --driver remote --endpoint <this>`. Empty when buildkitd is disabled."
  value       = local.buildkitd_enabled ? "tcp://${kubernetes_service_v1.buildkitd[0].metadata[0].name}.${kubernetes_namespace_v1.buildkitd[0].metadata[0].name}.svc.cluster.local:1234" : ""
}
