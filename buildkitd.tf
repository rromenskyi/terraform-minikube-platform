# Cluster-internal BuildKit daemon for self-hosted runner image
# builds. Single shared `buildkitd` Pod exposes its gRPC API on
# `tcp://buildkitd.arc-buildkitd.svc.cluster.local:1234` —
# workflows on ARC-managed runners hit it via
# `docker buildx create --driver remote --use --bootstrap` +
# `docker buildx build`. Cache slabs live on a hostPath so
# sequential builds reuse layers across runner pods (which are
# ephemeral). hostPath survives Pod restarts but pins the daemon
# to one node — single-replica + node_selector keeps the cache
# stable.
#
# Why standalone vs `--driver kubernetes` (per-job buildkitd Pod):
# the kubernetes driver creates / destroys a buildkitd Pod per
# build, which (a) needs RBAC on the runner SA to manage Pods,
# (b) loses cache on every job teardown. Single shared daemon
# trades isolation between concurrent builds (one warm cache,
# possible cache poisoning if untrusted code runs in CI) for
# warm-cache build speed and zero RBAC delegation.
#
# Trust model: CERN userns pattern. The container runs with
# `securityContext.privileged: true` (buildkit's OCI worker
# needs CAP_SYS_ADMIN to set up overlayfs / mount the build
# rootfs) BUT under `hostUsers: false` — the privileged uid 0
# inside the container is remapped through a user-namespace to
# an unprivileged uid on the host. The Pod is "privileged inside
# its userns, unprivileged on the host", and the kernel — not
# PSA — is what limits the blast radius. This needs:
#   - `pod-security.kubernetes.io/enforce: privileged` on the ns
#     (PSA admission lets `privileged: true` through)
#   - `hostUsers: false` in the Pod spec (Kubernetes 1.30 alpha,
#     1.34 beta — k3s on this cluster runs 1.34.6)
#
# Why `kubectl_manifest` and not `kubernetes_deployment_v1`: the
# upstream `hashicorp/kubernetes` provider 2.x has no schema
# field for `pod.spec.hostUsers`, so the only way to set the
# field is the raw-YAML resource type from the `gavinbunney/
# kubectl` provider.
#
# Image: `moby/buildkit:<ver>` — rootful. The rootless variant
# (`-rootless` tag) needs unprivileged user-namespace creation,
# which Ubuntu 23.10+ blocks by default at the AppArmor
# `userns_create` LSM hook unless that hook is opened up
# host-wide via sysctl. CERN privileged-in-userns sidesteps the
# hook and is the upstream-documented production pattern.

locals {
  buildkitd_enabled   = local.platform.services.buildkitd.enabled
  buildkitd_namespace = "arc-buildkitd"
}

resource "kubernetes_namespace_v1" "buildkitd" {
  for_each = local.buildkitd_enabled ? toset(["enabled"]) : toset([])

  metadata {
    name = local.buildkitd_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "buildkitd"
      # Privileged because the container sets `privileged: true`.
      # The blast radius is contained by `hostUsers: false`
      # (kernel userns remapping), not by PSA — see file header
      # for the trust model.
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "kubectl_manifest" "buildkitd" {
  for_each = local.buildkitd_enabled ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "buildkitd"
      namespace = kubernetes_namespace_v1.buildkitd["enabled"].metadata[0].name
      labels = {
        "app.kubernetes.io/name"      = "buildkitd"
        "app.kubernetes.io/component" = "buildkitd"
      }
    }
    spec = {
      # Single replica — one shared cache. Scaling out fragments
      # cache locality (each Pod's hostPath is independent on its
      # node) and would need a session-affinity layer in front of
      # the Service to keep a build pinned to its warm replica.
      replicas = 1
      selector = {
        matchLabels = { "app.kubernetes.io/name" = "buildkitd" }
      }
      strategy = {
        # Recreate not RollingUpdate: hostPath cache is
        # node-pinned and we don't want two Pods racing on the
        # same files during a rollover.
        type = "Recreate"
      }
      template = {
        metadata = {
          labels = { "app.kubernetes.io/name" = "buildkitd" }
        }
        spec = {
          hostUsers    = false
          nodeSelector = local.platform.services.buildkitd.node_selector
          tolerations  = local.platform.services.buildkitd.tolerations
          containers = [{
            name  = "buildkitd"
            image = "moby/buildkit:${local.platform.services.buildkitd.image_tag}"
            args = [
              "--addr",
              "unix:///run/buildkit/buildkitd.sock",
              "--addr",
              "tcp://0.0.0.0:1234",
            ]
            ports = [{
              containerPort = 1234
              name          = "grpc"
              protocol      = "TCP"
            }]
            securityContext = {
              privileged = true
            }
            readinessProbe = {
              exec = {
                command = ["buildctl", "debug", "workers"]
              }
              initialDelaySeconds = local.platform.services.buildkitd.readiness_initial_delay_seconds
              periodSeconds       = local.platform.services.buildkitd.readiness_period_seconds
              timeoutSeconds      = local.platform.services.buildkitd.readiness_timeout_seconds
              failureThreshold    = local.platform.services.buildkitd.readiness_failure_threshold
            }
            volumeMounts = [{
              name      = "cache"
              mountPath = local.platform.services.buildkitd.mount_path
            }]
            resources = {
              requests = {
                cpu    = local.platform.services.buildkitd.cpu_request
                memory = local.platform.services.buildkitd.memory_request
              }
              limits = {
                cpu    = local.platform.services.buildkitd.cpu_limit
                memory = local.platform.services.buildkitd.memory_limit
              }
            }
          }]
          volumes = [{
            name = "cache"
            hostPath = {
              path = local.platform.services.buildkitd.host_path
              type = "DirectoryOrCreate"
            }
          }]
        }
      }
    }
  })

  wait_for_rollout = true
  depends_on       = [kubernetes_namespace_v1.buildkitd]
}

resource "kubernetes_service_v1" "buildkitd" {
  for_each = local.buildkitd_enabled ? toset(["enabled"]) : toset([])

  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.buildkitd["enabled"].metadata[0].name
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
  value       = local.buildkitd_enabled ? "tcp://${kubernetes_service_v1.buildkitd["enabled"].metadata[0].name}.${kubernetes_namespace_v1.buildkitd["enabled"].metadata[0].name}.svc.cluster.local:1234" : ""
}
