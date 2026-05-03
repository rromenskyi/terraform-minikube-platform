# Argo CD — application-layer GitOps controller.
#
# Deploys the upstream `argo/argo-cd` Helm chart with the chart-side
# Ingress disabled. The platform owns ingress concerns elsewhere
# (Cloudflare Tunnel + Traefik IngressRoute) so the route lands as a
# `kind: external` component pointing at the `argocd-server` Service
# this chart creates.
#
# OIDC is wired through Dex's built-in OIDC connector. Caller is
# responsible for creating the Zitadel application (see
# `argocd.tf` at the root) and passing in `client_id` /
# `client_secret`. Empty inputs collapse the OIDC config and the
# install falls back to the chart-generated local `admin` account.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# ── Inputs ─────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Whether to deploy Argo CD. False collapses every resource — single-node clusters that don't need GitOps stay clean."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Argo CD lives in. Created by the chart's `create_namespace = true` so the operator doesn't have to declare it elsewhere."
  type        = string
  default     = "argocd"
}

variable "version_pin" {
  description = "Helm chart version for argo/argo-cd. Pinned so an upstream re-tag doesn't silently change behavior across applies. Bump deliberately when a new chart fixes a CVE or ships a desired feature."
  type        = string
  default     = "9.5.11"
}

variable "hostname" {
  description = "Public hostname Argo CD answers on. Embedded as `server.config.url` so generated redirect URIs and webhook callbacks resolve back to the public face."
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer URL. When set together with `oidc_client_id` and `oidc_client_secret`, the chart wires Dex with an OIDC connector and the UI gets a `Sign in with OIDC` button. Empty inputs disable the integration; only the chart-generated local admin remains."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "Client ID for the OIDC application Argo CD uses. Caller is responsible for creating the application in Zitadel and propagating the value here."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "Client secret for the OIDC application Argo CD uses. Sensitive — the value lands in a Helm-managed Secret inside the cluster."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_admin_groups" {
  description = "Group / role claims granted Argo CD's `role:admin` policy. Anyone whose ID token carries one of these claims gets full read/write across every Application/AppProject. Empty list = OIDC users have no permissions until the operator hand-edits the in-cluster ConfigMap."
  type        = list(string)
  default     = []
}

variable "node_selector" {
  description = "Node-selector applied to every Argo CD pod the chart creates (server, repo-server, application-controller, redis, dex). Empty = scheduler picks. Set on multi-node clusters where a specific tier should host the GitOps controller."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints every Argo CD pod tolerates. Empty list = pods cannot land on any tainted node."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

# ── Locals ────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  oidc_complete = (
    var.oidc_issuer != "" &&
    var.oidc_client_id != "" &&
    var.oidc_client_secret != ""
  )

  # Chart values. `commonLabels` propagates to every chart-rendered
  # resource. Server-config is built conditionally so empty OIDC
  # inputs don't render a half-shaped `oidc.config` block.
  values = yamlencode({
    global = {
      nodeSelector = var.node_selector
      tolerations = [
        for t in var.tolerations : {
          key               = t.key
          operator          = t.operator
          value             = t.value
          effect            = t.effect
          tolerationSeconds = try(tonumber(t.toleration_seconds), null)
        }
      ]
    }

    configs = {
      cm = merge(
        {
          url = "https://${var.hostname}"
        },
        local.oidc_complete ? {
          "oidc.config" = yamlencode({
            name         = "OIDC"
            issuer       = var.oidc_issuer
            clientID     = var.oidc_client_id
            clientSecret = var.oidc_client_secret
            requestedScopes = [
              "openid",
              "profile",
              "email",
              "groups",
            ]
            requestedIDTokenClaims = {
              groups = { essential = true }
            }
          })
        } : {}
      )

      rbac = length(var.oidc_admin_groups) == 0 ? {} : {
        "policy.csv" = join("\n", [
          for grp in var.oidc_admin_groups :
          "g, ${grp}, role:admin"
        ])
        scopes = "[groups]"
      }
    }

    # Chart-side Ingress stays off by design. The platform's
    # IngressRoute (rendered by modules/project from a `kind:
    # external` component yaml) routes Cloudflare Tunnel traffic to
    # the `argocd-server` Service the chart creates — owning ingress
    # in two places at once would conflict at the IngressClass level.
    server = {
      ingress = {
        enabled = false
      }
    }
  })
}

# ── Resources ─────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  for_each = local.instances

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.version_pin
  namespace  = var.namespace
  # Namespace owned by the caller — the OIDC Secret rendered by
  # `module.argocd_oidc` lands in the same namespace and needs it
  # to exist before the chart upgrade hook fires.
  create_namespace = false

  # Chart bring-up is heavier than monitoring (operator + repo-server
  # + application-controller + dex + redis). 15 min covers cold image
  # pulls on a slow link without masking real failures.
  timeout = 900

  values = [local.values]
}

# ── Outputs ───────────────────────────────────────────────────────────────

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace Argo CD lives in. Null when disabled."
}

output "service_name" {
  value       = var.enabled ? "argocd-server" : null
  description = "ClusterIP Service name for the Argo CD UI/API. Wired into a `kind: external` component yaml so the IngressRoute pipeline routes the public hostname here. Null when disabled."
}

output "service_port" {
  value       = var.enabled ? 80 : null
  description = "Service port the IngressRoute should target. Null when disabled."
}
