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

# ── Shared-IP annotations on existing Services ────────────────────────────
#
# Annotates a Service that another controller (Helm chart, ArgoCD)
# owns, without claiming ownership of the Service itself.
# `kubernetes_annotations` patches only the listed annotation keys
# server-side — the rest of the Service spec stays under the
# original owner's reconciliation. Helm / ArgoCD do not strip
# annotations they don't manage, so this persists across upgrades.

resource "kubernetes_annotations" "shared_ip" {
  for_each = var.enabled ? var.shared_ip_annotations : {}

  depends_on = [helm_release.metallb]

  api_version = "v1"
  kind        = "Service"
  metadata {
    name      = split("/", each.key)[1]
    namespace = split("/", each.key)[0]
  }
  # MetalLB v0.15+ recognises only the canonical `metallb.io/...`
  # annotation prefix for sharing-key extraction. The legacy
  # `metallb.universe.tf/...` form still fires a `deprecatedAnnotation`
  # warn in controller logs but is read as empty for sharing-key
  # purposes — a Service with only legacy annotations cannot share a
  # VIP with a canonical-annotated Service even when values match.
  # Tenant charts that still emit legacy annotations need to migrate
  # to the canonical prefix on their side.
  annotations = {
    "metallb.io/allow-shared-ip" = each.value
  }
}

