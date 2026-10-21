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

variable "node_hostnames" {
  description = "Further limits the Satellite and CSI node plugin nodes to these hostnames (`kubernetes.io/hostname`), on top of `node_selector`. Empty = every `node_selector` node. List only nodes that have DRBD 9 loaded: Kubernetes schedules pods with Piraeus volumes onto any node with the CSI node plugin, and on a node without DRBD 9 the volume cannot attach, so a node that joins later stays out until it is listed."
  type        = list(string)
  default     = []
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
      - zfs_thin_pool: existing ZFS pool or dataset (e.g. "tank/k8s") to
        carve thin zvols from
      - key: optional, defaults to `name`. Needed to declare one pool name
        on several nodes with different selectors (two entries `name: k8s`
        with keys `k8s` and `k8s-node2`): `node_selector` matches labels
        only. Keep an existing entry's key unchanged — a new key recreates
        its LinstorSatelliteConfiguration.
  EOT
  type = list(object({
    name          = string
    node_selector = map(string)
    zfs_thin_pool = string
    key           = optional(string)
  }))
  default = []
}

variable "storage_classes" {
  description = <<-EOT
    StorageClasses (provisioner linstor.csi.linbit.com):
      - name, storage_pool, placement_count (copies of each volume)
      - fs_type (ext4 or xfs), reclaim_policy (Delete or Retain), default (bool)
      - resource_group: LINSTOR resource group the volumes are spawned from
        (created on first use). Empty: LINSTOR names it sc-<hash>. See the
        README for raising the copies of existing volumes.
  EOT
  type = list(object({
    name            = string
    storage_pool    = string
    placement_count = optional(number, 1)
    fs_type         = optional(string, "ext4")
    reclaim_policy  = optional(string, "Retain")
    default         = optional(bool, false)
    resource_group  = optional(string, "")
  }))
  default = []
}

variable "monitoring" {
  description = "PodMonitors for the LINSTOR controller (`/metrics` on its API port) and the Satellites' drbd-reactor, plus alerts on both (needs the Prometheus Operator CRDs)."
  type        = bool
  default     = false
}

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects PodMonitors and PrometheusRules by."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
}
