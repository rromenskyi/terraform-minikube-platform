variable "enabled" {
  description = "Whether to install Piraeus Datastore (LINSTOR + DRBD + CSI). False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace of the operator and the LINSTOR cluster."
  type        = string
  default     = "piraeus-datastore"
}

variable "operator_chart_version" {
  description = "Version of the `piraeus` Helm chart (oci://ghcr.io/piraeusdatastore/piraeus-operator), which equals the operator version."
  type        = string
}

variable "node_selector" {
  description = "Labels of the nodes that run LINSTOR Satellites and the CSI node plugin. Only pods on these nodes can use Piraeus volumes."
  type        = map(string)
}

variable "control_plane_node_selector" {
  description = "Labels of the nodes for the operator, the LINSTOR controller and the CSI controller. Empty = anywhere."
  type        = map(string)
  default     = {}
}

variable "host_network" {
  description = "Run the Satellites in the host network, so DRBD replicates over the nodes' own addresses and routes (and survives a Satellite pod restart)."
  type        = bool
  default     = true
}

variable "drbd_loader_mode" {
  description = "How the DRBD module loader init container loads DRBD (`LB_HOW`). \"deps_only\": DRBD 9 is provided by the host (e.g. DKMS); only helper modules are loaded. Empty: the loader's default (build DRBD from source in the container)."
  type        = string
  default     = "deps_only"
}

variable "storage_pools" {
  description = <<-EOT
    LINSTOR storage pools, each on the nodes matching `node_selector`:
      - name: the storage pool name used by StorageClasses
      - zfs_thin_pool: existing ZFS pool (zpool) to carve thin zvols from
  EOT
  type = list(object({
    name          = string
    node_selector = map(string)
    zfs_thin_pool = string
  }))
  default = []
}

variable "storage_classes" {
  description = <<-EOT
    StorageClasses (provisioner linstor.csi.linbit.com):
      - name, storage_pool, placement_count (copies of each volume)
      - fs_type (ext4 or xfs), reclaim_policy (Delete or Retain), default (bool)
  EOT
  type = list(object({
    name            = string
    storage_pool    = string
    placement_count = optional(number, 1)
    fs_type         = optional(string, "ext4")
    reclaim_policy  = optional(string, "Retain")
    default         = optional(bool, false)
  }))
  default = []
}
