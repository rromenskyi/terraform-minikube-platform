# Piraeus Datastore: the Piraeus operator (Helm) runs LINSTOR (controller +
# one Satellite per selected node), DRBD replication and the LINSTOR CSI
# driver. Storage comes from pools on the Satellites (here: thin zvols in an
# existing ZFS pool); StorageClasses expose them to PVCs.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
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

locals {
  set = var.enabled ? toset(["enabled"]) : toset([])
  # Pod template fragment pinning a component to the control-plane nodes.
  cp_pin = length(var.control_plane_node_selector) > 0 ? { nodeSelector = var.control_plane_node_selector } : {}
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.set
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "operator" {
  for_each = local.set

  name        = "piraeus-operator"
  repository  = "oci://ghcr.io/piraeusdatastore/piraeus-operator"
  chart       = "piraeus"
  version     = var.operator_chart_version
  namespace   = kubernetes_namespace_v1.this["enabled"].metadata[0].name
  max_history = 3

  values = [yamlencode({
    installCRDs  = true
    nodeSelector = var.control_plane_node_selector
  })]
}

resource "kubectl_manifest" "cluster" {
  for_each   = local.set
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorCluster"
    metadata   = { name = "linstorcluster" }
    spec = {
      nodeSelector  = var.node_selector
      controller    = { podTemplate = { spec = local.cp_pin } }
      csiController = { podTemplate = { spec = local.cp_pin } }
    }
  })
}

# DRBD replicates over the nodes' own addresses (and their routes), not the
# pod network.
resource "kubectl_manifest" "host_network" {
  for_each   = var.enabled && var.host_network ? toset(["enabled"]) : toset([])
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorSatelliteConfiguration"
    metadata   = { name = "host-network" }
    spec       = { podTemplate = { spec = { hostNetwork = true } } }
  })
}

resource "kubectl_manifest" "drbd_loader" {
  for_each   = var.enabled && var.drbd_loader_mode != "" ? toset(["enabled"]) : toset([])
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorSatelliteConfiguration"
    metadata   = { name = "drbd-loader" }
    spec = {
      podTemplate = {
        spec = {
          initContainers = [{
            name = "drbd-module-loader"
            env  = [{ name = "LB_HOW", value = var.drbd_loader_mode }]
          }]
        }
      }
    }
  })
}

resource "kubectl_manifest" "storage_pool" {
  for_each   = var.enabled ? { for p in var.storage_pools : p.name => p } : {}
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorSatelliteConfiguration"
    metadata   = { name = "storage-pool-${each.key}" }
    spec = {
      nodeSelector = each.value.node_selector
      storagePools = [{
        name        = each.key
        zfsThinPool = { zPool = each.value.zfs_thin_pool }
      }]
    }
  })
}

resource "kubernetes_storage_class_v1" "this" {
  for_each = var.enabled ? { for sc in var.storage_classes : sc.name => sc } : {}

  metadata {
    name = each.key
    annotations = each.value.default ? {
      "storageclass.kubernetes.io/is-default-class" = "true"
    } : {}
  }
  storage_provisioner    = "linstor.csi.linbit.com"
  reclaim_policy         = each.value.reclaim_policy
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = merge(
    {
      "linstor.csi.linbit.com/storagePool"    = each.value.storage_pool
      "linstor.csi.linbit.com/placementCount" = tostring(each.value.placement_count)
      "csi.storage.k8s.io/fstype"             = each.value.fs_type
    },
    each.value.resource_group != "" ? { "linstor.csi.linbit.com/resourceGroup" = each.value.resource_group } : {},
  )
}
