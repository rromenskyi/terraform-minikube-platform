# GitHub self-hosted runners via ARC (Actions Runner Controller).
#
# Modern path: GitHub-maintained ARC v0.9+ ships two charts —
# `gha-runner-scale-set-controller` (one per cluster, watches the
# AutoscalingRunnerSet CRD) and `gha-runner-scale-set` (one per
# runner pool, registers with a specific org / repo / enterprise
# URL via the GitHub Actions API). The controller's listener-pod
# pattern replaced the older KEDA-based ARC: it polls GitHub for
# queued workflow_jobs and creates / deletes runner pods directly,
# scaling 0 → max_runners and back as the queue drains. No KEDA
# needed.
#
# Authentication is per-scale-set: either a GitHub App (org-wide,
# preferred) or a PAT (token-scoped to a single org / repo / user
# context). The engine accepts both via the operator-supplied
# Secret name input — engine doesn't store the credential, just
# wires the Secret reference into the chart values.
#
# Source-IP / network egress: runners pull from GitHub's HTTPS API
# only — no L4 ingress need on the cluster side, no MetalLB
# concern. Outbound bandwidth + image-pull caching is the usual
# bottleneck on self-hosted; sizing comes from the operator's
# observed CI workload.

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
  description = "Whether to install ARC controller + any scale sets. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace_controller" {
  description = "Namespace for the cluster-wide ARC controller. The controller is shared across every scale set; scale-set runner pods land in their own per-set namespaces (see `scale_sets[].namespace`)."
  type        = string
  default     = "arc-system"
}

variable "controller_chart_version" {
  description = "Pinned chart version for `gha-runner-scale-set-controller`. Pin both controller and scale-set chart to the same version — they share a CRD that crosses both releases, and a version skew can break listener-pod creation."
  type        = string
  default     = "0.9.3"
}

variable "scale_set_chart_version" {
  description = "Pinned chart version for `gha-runner-scale-set`. Match the controller's version (see `controller_chart_version`)."
  type        = string
  default     = "0.9.3"
}

variable "controller_node_selector" {
  description = "Node selector for the controller Deployment. Empty = scheduler picks. Pin to a stable tier (e.g. `{ workload-tier: general }`) so the controller doesn't bounce onto edge nodes."
  type        = map(string)
  default     = {}
}

variable "controller_tolerations" {
  description = "Tolerations for the controller Deployment. Standard k8s toleration shape."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "scale_sets" {
  description = "Map of runner scale sets to install. Map key is the scale-set name (also the chart release name and the runner label set's identifier). Each entry: `github_config_url` (full URL — `https://github.com/<org>` or `https://github.com/<org>/<repo>` or `https://github.com/enterprises/<ent>`), `github_secret_name` (k8s Secret in the scale-set's namespace carrying either `github_token` for PAT auth or `github_app_id` + `github_app_installation_id` + `github_app_private_key` for GitHub App auth — engine does NOT create this Secret, operator pre-creates it), `namespace` (where the runner pods + listener land — engine creates it), `min_runners` (int, default 0 — scale to zero between jobs is the default; set ≥1 to keep warm runners), `max_runners` (int, default 4 — upper bound on concurrent runners; pick based on cluster headroom), `runner_image` (defaults to GitHub's hosted image equivalent), `runner_resources` (k8s resources block), `runner_node_selector` / `runner_tolerations` (placement for runner pods, separate from controller). Empty map = no scale sets, controller still installs (cheap to leave running)."
  type = map(object({
    github_config_url    = string
    github_secret_name   = string
    namespace            = string
    min_runners          = optional(number, 0)
    max_runners          = optional(number, 4)
    runner_image         = optional(string, "ghcr.io/actions/actions-runner:latest")
    runner_resources     = optional(any, {})
    runner_node_selector = optional(map(string), {})
    runner_tolerations = optional(list(object({
      key      = optional(string)
      operator = optional(string, "Exists")
      value    = optional(string)
      effect   = optional(string)
    })), [])
  }))
  default = {}
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances         = var.enabled ? toset(["enabled"]) : toset([])
  scale_set_targets = var.enabled ? var.scale_sets : {}
  # Each scale set lands in its own namespace — engine creates them
  # idempotently rather than asking the operator to pre-create.
  scale_set_namespaces = distinct([for _, s in local.scale_set_targets : s.namespace])
}

# ── Controller namespace + chart ───────────────────────────────────────────

resource "kubernetes_namespace_v1" "controller" {
  for_each = local.instances

  metadata {
    name = var.namespace_controller
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-controller"
    }
  }
}

resource "helm_release" "controller" {
  for_each = local.instances

  name             = "arc-controller"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = var.controller_chart_version
  namespace        = kubernetes_namespace_v1.controller["enabled"].metadata[0].name
  create_namespace = false

  values = [yamlencode({
    nodeSelector = var.controller_node_selector
    tolerations  = var.controller_tolerations
  })]
}

# ── Per-scale-set namespaces ───────────────────────────────────────────────

resource "kubernetes_namespace_v1" "scale_set" {
  for_each = toset(local.scale_set_namespaces)

  metadata {
    name = each.key
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-runners"
    }
  }
}

# ── Scale sets ─────────────────────────────────────────────────────────────

resource "helm_release" "scale_set" {
  for_each = local.scale_set_targets

  depends_on = [
    helm_release.controller,
    kubernetes_namespace_v1.scale_set,
  ]

  name             = each.key
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.scale_set_chart_version
  namespace        = each.value.namespace
  create_namespace = false

  values = [yamlencode({
    githubConfigUrl    = each.value.github_config_url
    githubConfigSecret = each.value.github_secret_name
    minRunners         = each.value.min_runners
    maxRunners         = each.value.max_runners
    template = {
      spec = {
        nodeSelector = each.value.runner_node_selector
        tolerations  = each.value.runner_tolerations
        containers = [{
          name      = "runner"
          image     = each.value.runner_image
          command   = ["/home/runner/run.sh"]
          resources = each.value.runner_resources
        }]
      }
    }
  })]
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "controller_namespace" {
  description = "Namespace where the ARC controller is installed. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace_controller : ""
}

output "scale_set_names" {
  description = "List of installed scale set names (matches operator-configured map keys). Empty when disabled or no scale sets configured."
  value       = [for k, _ in local.scale_set_targets : k]
}
