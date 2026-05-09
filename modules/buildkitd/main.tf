# Cluster-internal BuildKit daemon for self-hosted runner image
# builds. Single shared `buildkitd` Pod exposes its gRPC API on
# `tcp://buildkitd.<namespace>.svc.cluster.local:1234` — workflows on
# ARC-managed runners hit it via `docker buildx create --driver
# remote --use --bootstrap` + `docker buildx build`. Cache slabs
# live on a hostPath so sequential builds reuse layers across runner
# pods (which are ephemeral). hostPath survives Pod restarts but
# pins the daemon to one node — single-replica + node_selector
# keeps the cache stable.
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
# `securityContext.privileged: true` (buildkit's OCI worker needs
# CAP_SYS_ADMIN to set up overlayfs / mount the build rootfs) BUT
# under `hostUsers: false` — the privileged uid 0 inside the
# container is remapped through a user-namespace to an
# unprivileged uid on the host. The Pod is "privileged inside its
# userns, unprivileged on the host", and the kernel — not PSA — is
# what limits the blast radius. This needs:
#   - `pod-security.kubernetes.io/enforce: privileged` on the ns
#     (PSA admission lets `privileged: true` through)
#   - `hostUsers: false` in the Pod spec (Kubernetes 1.30 alpha,
#     1.34 beta — k3s on this cluster runs 1.34.6)
#
# Why `kubectl_manifest` and not `kubernetes_deployment_v1`: the
# upstream `hashicorp/kubernetes` provider 2.x has no schema field
# for `pod.spec.hostUsers`, so the only way to set the field is the
# raw-YAML resource type from the `gavinbunney/kubectl` provider.
#
# Image: `moby/buildkit:<ver>` — rootful. The rootless variant
# (`-rootless` tag) needs unprivileged user-namespace creation,
# which Ubuntu 23.10+ blocks by default at the AppArmor
# `userns_create` LSM hook unless that hook is opened up host-wide
# via sysctl. CERN privileged-in-userns sidesteps the hook and is
# the upstream-documented production pattern.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`). Tags propagate
# down — operator-stamped tags at the platform tier land on every
# resource this module emits via `module.label.tags` in
# `metadata.labels`.
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "buildkitd"
  tags = {
    "app.kubernetes.io/component" = "buildkitd"
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(module.label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "buildkitd"
      # Privileged because the container sets `privileged: true`.
      # The blast radius is contained by `hostUsers: false`
      # (kernel userns remapping), not by PSA — see file header
      # for the trust model.
      "pod-security.kubernetes.io/enforce" = "privileged"
    })
  }
}

resource "kubectl_manifest" "this" {
  for_each = local.instances

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "buildkitd"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels = merge(module.label.tags, {
        "app.kubernetes.io/name"      = "buildkitd"
        "app.kubernetes.io/component" = "buildkitd"
      })
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
          nodeSelector = var.node_selector
          tolerations  = var.tolerations
          containers = [{
            name  = "buildkitd"
            image = "moby/buildkit:${var.image_tag}"
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
              initialDelaySeconds = var.readiness_initial_delay_seconds
              periodSeconds       = var.readiness_period_seconds
              timeoutSeconds      = var.readiness_timeout_seconds
              failureThreshold    = var.readiness_failure_threshold
            }
            volumeMounts = [{
              name      = "cache"
              mountPath = var.mount_path
            }]
            resources = {
              requests = {
                cpu    = var.cpu_request
                memory = var.memory_request
              }
              limits = {
                cpu    = var.cpu_limit
                memory = var.memory_limit
              }
            }
          }]
          volumes = [{
            name = "cache"
            hostPath = {
              path = var.host_path
              type = "DirectoryOrCreate"
            }
          }]
        }
      }
    }
  })

  wait_for_rollout = true
  depends_on       = [kubernetes_namespace_v1.this]
}

resource "kubernetes_service_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "buildkitd"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels = merge(module.label.tags, {
      "app.kubernetes.io/name"      = "buildkitd"
      "app.kubernetes.io/component" = "buildkitd"
    })
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
