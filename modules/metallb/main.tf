# MetalLB — bare-metal LoadBalancer for k8s on a self-hosted /
# VPS cluster. Enables `Service type: LoadBalancer` to allocate
# real on-network IPs (instead of the cloud-controller no-op
# that leaves them stuck in <pending>).
#
# L2 mode only — no BGP. One node per VIP announces via
# gratuitous ARP. Source-IP preservation requires the consuming
# Service to set `externalTrafficPolicy: Local` AND the backend
# pod to land on the announcing node (kube-proxy does not
# forward traffic across nodes when Local is set; it drops if
# no local backend exists). Multi-replica horizontal scale on
# L2 = DaemonSet pattern (pod on every node that has a speaker)
# or multiple Services with distinct VIPs. True multi-active
# fronting one VIP needs BGP mode + an upstream router that
# speaks BGP — out of scope for this module.
#
# The chart's controller picks IPs from configured pools; speaker
# DaemonSet does the L2 announcement. Pools and L2Advertisements
# are CRDs the operator config defines per intent.

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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# ── Inputs ─────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Whether to deploy MetalLB. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace MetalLB lives in. Convention is `metallb-system`; the chart's controller and speaker reference each other via in-namespace Services and the CRD validating webhook is namespace-bound, so override only if a fleet-wide policy requires a different one."
  type        = string
  default     = "metallb-system"
}

variable "version_pin" {
  description = "Helm chart version for metallb/metallb. Pinned so an upstream re-tag doesn't change CRD shape or defaults across applies."
  type        = string
  default     = "0.14.9"
}

variable "controller_node_selector" {
  description = "Node selector for the MetalLB controller Deployment. Controller is stateless and picks IPs from pools — it can run anywhere with cluster API access. Empty map = land wherever k8s schedules. Set to a stable tier (e.g. `{ workload-tier: general }`) to avoid the controller bouncing onto edge / tainted nodes."
  type        = map(string)
  default     = {}
}

variable "controller_tolerations" {
  description = "Tolerations for the MetalLB controller. Standard k8s toleration shape. Empty = controller lands only on un-tainted nodes."
  type = list(object({
    key                = optional(string)
    operator           = optional(string, "Exists")
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "speaker_node_selector" {
  description = "Node selector for the speaker DaemonSet. The speaker MUST land on the node(s) that should announce VIPs via L2 ARP — the IP physically arrives on that node's NIC. Restricting via nodeSelector keeps speaker pods off nodes that have no business announcing (e.g. home nodes that aren't on the public network). Empty map = speaker DaemonSet lands on every (un-tainted) node, which is the chart default but rarely what you want for a multi-tier cluster."
  type        = map(string)
  default     = {}
}

variable "speaker_tolerations" {
  description = "Tolerations for the speaker DaemonSet. If the announcing node is tainted (e.g. dedicated-app taint on a VPS that also serves as the LB ingress node), the speaker must tolerate the taint to land there. Standard k8s toleration shape. Empty = speaker lands only on un-tainted nodes."
  type = list(object({
    key                = optional(string)
    operator           = optional(string, "Exists")
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "pools" {
  description = "IP address pools MetalLB allocates from. Each entry produces one `IPAddressPool` CRD plus, when `l2_node_selectors` is non-empty, one `L2Advertisement` CRD restricting which nodes announce the pool's IPs via ARP (avoids split-brain ARP from multiple speakers offering the same VIP). Map key is the pool name (also used as CRD object name). `addresses` is a list of CIDRs or `start-end` ranges in MetalLB's native syntax. `auto_assign` controls whether unallocated IPs in the pool can be auto-picked for `Service type: LoadBalancer` without an explicit `loadBalancerIP` request — set false for tightly-controlled pools where every Service must opt in by name. `l2_node_selectors` is a list of label-selector maps that becomes the `L2Advertisement.spec.nodeSelectors` field; restricts which nodes announce these IPs (defaults to all nodes with a speaker if empty). Empty `pools` map = MetalLB installed but inert."
  type = map(object({
    addresses         = list(string)
    auto_assign       = optional(bool, true)
    l2_node_selectors = optional(list(map(string)), [])
  }))
  default = {}
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
}

# ── Namespace ──────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "metallb" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = {
      # MetalLB's webhook expects this label so its ValidatingAdmissionWebhook
      # can scope CRD validation correctly. Skipping it makes IPAddressPool /
      # L2Advertisement creates fail with "namespace not found by webhook".
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# ── Helm chart ─────────────────────────────────────────────────────────────

resource "helm_release" "metallb" {
  for_each = local.instances

  name             = "metallb"
  repository       = "https://metallb.github.io/metallb"
  chart            = "metallb"
  version          = var.version_pin
  namespace        = kubernetes_namespace_v1.metallb["enabled"].metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    controller = {
      nodeSelector = var.controller_node_selector
      tolerations  = var.controller_tolerations
    }
    speaker = {
      nodeSelector = var.speaker_node_selector
      tolerations  = var.speaker_tolerations
      # L2 mode does not need BGP daemon; chart bundles FRR as
      # opt-in for BGP. Keep it disabled — fewer moving parts,
      # smaller speaker pod footprint.
      frr = {
        enabled = false
      }
    }
  })]
}

# ── Pools + L2 advertisements ──────────────────────────────────────────────
#
# Both CRDs live under metallb.io/v1beta1. Created via raw manifest
# because the kubernetes provider's `kubernetes_manifest` resource
# requires the cluster-side CRD to exist at plan time, which fails
# on a fresh apply where the chart installs the CRD in the same
# run. `kubectl_manifest` defers the read until apply, sidestepping
# the chicken-and-egg.

resource "kubectl_manifest" "ip_pool" {
  for_each = var.enabled ? var.pools : {}

  depends_on = [helm_release.metallb]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "IPAddressPool"
    metadata = {
      name      = each.key
      namespace = var.namespace
    }
    spec = {
      addresses  = each.value.addresses
      autoAssign = each.value.auto_assign
    }
  })
}

resource "kubectl_manifest" "l2_advertisement" {
  for_each = var.enabled ? {
    for k, v in var.pools : k => v
    if length(v.l2_node_selectors) > 0
  } : {}

  depends_on = [kubectl_manifest.ip_pool]

  yaml_body = yamlencode({
    apiVersion = "metallb.io/v1beta1"
    kind       = "L2Advertisement"
    metadata = {
      name      = each.key
      namespace = var.namespace
    }
    spec = {
      ipAddressPools = [each.key]
      nodeSelectors = [
        for sel in each.value.l2_node_selectors : {
          matchLabels = sel
        }
      ]
    }
  })
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "namespace" {
  description = "Namespace MetalLB is installed in. Empty when `enabled = false`."
  value       = var.enabled ? var.namespace : ""
}

output "pools" {
  description = "Map of pool name → addresses, mirroring the input. Useful for downstream modules that want to assert a pool exists before requesting `loadBalancerIP` from it."
  value       = var.enabled ? { for k, v in var.pools : k => v.addresses } : {}
}
