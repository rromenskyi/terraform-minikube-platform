terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# Platform operator dashboard. SvelteKit app from
# `~/gh/platform-dash` packaged as a self-contained module so the
# dashboard can be promoted from a tenant-component to first-class
# platform infra without rewriting any of its k8s resources — only
# the call site changes.
#
# Currently NOT instantiated. Wiring deferred to a follow-up: the
# dashboard still ships through `modules/component` invoked by the
# project module against `config/domains/*.yaml`. This module keeps
# the future shape ready so the eventual call from
# `platform_dash.tf` (or from a domain-yaml router) is one block.
#
# What this module owns:
#   - ServiceAccount + ClusterRole + ClusterRoleBinding (read-wide,
#     narrow writes)
#   - Deployment (single replica by default; SvelteKit is a stateless
#     Node process)
#   - Service (ClusterIP, 80 → containerPort 3000)
#
# Out of scope here (lives upstream in whichever file calls this):
#   - OIDC integration via modules/zitadel-app (caller passes the
#     emitted Secret name + checksum)
#   - Cloudflare DNS record (root cloudflare.tf via all_hostnames)
#   - IngressRoute (caller emits the kubectl_manifest)
#   - DB target ConfigMap + creds Secret (platform_dash_db.tf)

# ── Inputs ───────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Whether to deploy the dashboard. Off → all resources count = 0."
  type        = bool
}

variable "namespace" {
  description = "Namespace to deploy into. Conventionally the shared `platform` namespace once promoted to first-class infra."
  type        = string
}

variable "image" {
  description = "Container image, tag included."
  type        = string
}

variable "replicas" {
  description = "Replica count. Defaults to 1; the dashboard is read-mostly so a single pod is enough."
  type        = number
  default     = 1
}

variable "resources" {
  description = "Pod resource requests/limits."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
}

variable "hostname" {
  description = "Public hostname the dashboard answers on. Embedded as ORIGIN / AUTH_URL so cookie + OIDC redirect generation produces the right scheme + host even when behind cloudflared."
  type        = string
}

variable "oidc_secret_name" {
  description = "Name of the Secret in `namespace` that holds AUTH_ZITADEL_ISSUER / AUTH_ZITADEL_ID / AUTH_ZITADEL_SECRET / AUTH_SECRET. Produced by modules/zitadel-app."
  type        = string
}

variable "oidc_secret_checksum" {
  description = "SHA1 of the OIDC Secret data, mounted as a `checksum/oidc` annotation so a Zitadel app rotation rolls the pod automatically."
  type        = string
}

variable "node_selector" {
  description = "Node-selector labels the platform-dash pod must match. Empty = scheduler picks. The dash is stateless and can run anywhere; pin via `{ workload-tier = general }` or similar to keep it off the data node."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints the platform-dash pod tolerates. Empty list = pod cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

# ── Naming ───────────────────────────────────────────────────────────────────

locals {
  app_name       = "platform-dash"
  cluster_role   = "${var.namespace}-${local.app_name}"
  port_container = 3000
  port_service   = 80
  labels = {
    "app.kubernetes.io/name"       = local.app_name
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "platform"
  }
}

# ── ServiceAccount ───────────────────────────────────────────────────────────

resource "kubernetes_service_account_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }
}

# ── ClusterRole ──────────────────────────────────────────────────────────────
# Read = wide (the generic CRD viewer fans out to dynamic groups so
# we can't enumerate every resource the dashboard might touch).
# Write = narrow: pod delete, deployment / statefulset patch + scale.
# CRD edit/delete is intentionally left out for now.

resource "kubernetes_cluster_role_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name   = local.cluster_role
    labels = local.labels
  }

  # Single-operator platform: the dashboard is the operator's main
  # surface for cluster admin, and every action button — scale,
  # restart, pod-delete, CRD replace/delete, ConfigMap edit — needs
  # write access against the matching API group. The previous narrow
  # rule set was missing `core/configmaps` (cm-replace endpoint),
  # CRD writes (crd-replace, crd-delete), and any verb on resources
  # the dashboard hasn't shipped UI for yet but adds in passing.
  # Operator hit "scale" / "restart" via the dash and got 403s
  # because the rule list didn't keep up.
  #
  # Authorisation gate is the dashboard pod itself — the OIDC layer
  # rejects anyone without `platform_admin` before any k8s API call
  # leaves the pod (see modules/platform-dash/main.tf cookie /
  # session check + dashboard's `canWrite` derivation in
  # ~/gh/platform-dash/src/lib/authz.ts). Anyone allowed past that
  # gate is, by design, equivalent to a cluster-admin on this
  # cluster — the single-operator trust boundary explicitly assumes
  # that. Add a narrower role + RoleBinding-by-namespace pattern if
  # a third party ever gets `platform_admin`.
  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name   = local.cluster_role
    labels = local.labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this[0].metadata[0].name
    namespace = var.namespace
  }
}

# ── Deployment ───────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.app_name
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # Drives a rollout when the OIDC Secret rotates so the pod
          # picks up the new client_id/client_secret instead of running
          # with stale env from its previous start.
          "checksum/oidc" = var.oidc_secret_checksum
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.this[0].metadata[0].name

        # Pod placement primitives — empty defaults preserve prior
        # scheduler behaviour.
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

        container {
          name              = local.app_name
          image             = var.image
          image_pull_policy = "Always"

          port {
            container_port = local.port_container
            name           = "http"
          }

          env_from {
            secret_ref {
              name = var.oidc_secret_name
            }
          }

          env {
            name  = "ORIGIN"
            value = "https://${var.hostname}"
          }
          env {
            name  = "AUTH_URL"
            value = "https://${var.hostname}"
          }
          # SvelteKit auto-detects scheme/host from these forwarded
          # headers when set — required behind cloudflared + Traefik
          # so OIDC callback URLs don't end up as http://...
          env {
            name  = "PROTOCOL_HEADER"
            value = "x-forwarded-proto"
          }
          env {
            name  = "HOST_HEADER"
            value = "x-forwarded-host"
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # Liveness / readiness both hit /healthz — the cheap endpoint
          # that doesn't touch the kube API. /readyz exists too (probes
          # kube API) but we deliberately use the cheap one for both so
          # transient API blips don't cycle the pod.
          liveness_probe {
            http_get {
              path = "/healthz"
              port = local.port_container
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = local.port_container
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
          startup_probe {
            http_get {
              path = "/healthz"
              port = local.port_container
            }
            period_seconds    = 10
            failure_threshold = 30
            timeout_seconds   = 5
          }
        }
      }
    }
  }
}

# ── Service ──────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = local.app_name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name" = local.app_name
    }
    port {
      name        = "http"
      port        = local.port_service
      target_port = local.port_container
      protocol    = "TCP"
    }
  }
}

# ── Outputs ──────────────────────────────────────────────────────────────────

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where the dashboard lives. Null when disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.this : s.metadata[0].name])
  description = "ClusterIP Service name (for IngressRoute target). Null when disabled."
}

output "service_port" {
  value       = local.port_service
  description = "Service port the IngressRoute should target."
}

output "service_account_name" {
  value       = one([for s in kubernetes_service_account_v1.this : s.metadata[0].name])
  description = "ServiceAccount name. Null when disabled."
}
