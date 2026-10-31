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
  # Node allow-list in addition to node_selector; the operator applies it
  # to every Piraeus workload, controllers included.
  satellite_affinity = length(var.node_hostnames) > 0 ? {
    nodeAffinity = {
      nodeSelectorTerms = [{
        matchExpressions = [{ key = "kubernetes.io/hostname", operator = "In", values = var.node_hostnames }]
      }]
    }
  } : {}
  cluster_properties = length(var.controller_properties) > 0 ? {
    properties = [for name, value in var.controller_properties : { name = name, value = value }]
  } : {}
  # NFS server only on the listed nodes. The operator applies this pod
  # template after its own node affinity patch, so it replaces it.
  nfs_server = length(var.nfs_server_node_hostnames) > 0 ? {
    nfsServer = {
      podTemplate = {
        spec = {
          affinity = {
            nodeAffinity = {
              requiredDuringSchedulingIgnoredDuringExecution = {
                nodeSelectorTerms = [{
                  matchExpressions = [{ key = "kubernetes.io/hostname", operator = "In", values = var.nfs_server_node_hostnames }]
                }]
              }
            }
          }
        }
      }
    }
  } : {}
  # Several CSI controller replicas only help on different nodes.
  csi_controller_spread = var.csi_controller_replicas > 1 ? {
    affinity = {
      podAntiAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = [{
          topologyKey   = "kubernetes.io/hostname"
          labelSelector = { matchLabels = { "app.kubernetes.io/component" = "linstor-csi-controller" } }
        }]
      }
    }
  } : {}
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
    spec = merge({
      nodeSelector  = var.node_selector
      controller    = { podTemplate = { spec = local.cp_pin } }
      csiController = { replicas = var.csi_controller_replicas, podTemplate = { spec = merge(local.cp_pin, local.csi_controller_spread) } }
    }, local.satellite_affinity, local.nfs_server, local.cluster_properties)
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
  for_each   = var.enabled ? { for p in var.storage_pools : coalesce(p.key, p.name) => p } : {}
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorSatelliteConfiguration"
    metadata   = { name = "storage-pool-${each.key}" }
    spec = {
      nodeSelector = each.value.node_selector
      storagePools = [{
        name        = each.value.name
        zfsThinPool = { zPool = each.value.zfs_thin_pool }
      }]
    }
  })
}

resource "kubectl_manifest" "satellite_properties" {
  for_each   = var.enabled ? var.satellite_properties : {}
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "piraeus.io/v1"
    kind       = "LinstorSatelliteConfiguration"
    metadata   = { name = "properties-${each.key}" }
    spec = {
      nodeAffinity = {
        nodeSelectorTerms = [{
          matchExpressions = [{ key = "kubernetes.io/hostname", operator = "In", values = each.value.node_hostnames }]
        }]
      }
      properties = [for name, value in each.value.properties : { name = name, value = value }]
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
  mount_options          = length(each.value.mount_options) > 0 ? each.value.mount_options : null
  parameters = merge(
    {
      "linstor.csi.linbit.com/storagePool"    = each.value.storage_pool
      "linstor.csi.linbit.com/placementCount" = tostring(each.value.placement_count)
      "csi.storage.k8s.io/fstype"             = each.value.fs_type
    },
    each.value.resource_group != "" ? { "linstor.csi.linbit.com/resourceGroup" = each.value.resource_group } : {},
    length(each.value.x_replicas_on_different) > 0 ? { "linstor.csi.linbit.com/xReplicasOnDifferent" = jsonencode(each.value.x_replicas_on_different) } : {},
    { for k, v in each.value.properties : "property.linstor.csi.linbit.com/${k}" => v },
  )
}
