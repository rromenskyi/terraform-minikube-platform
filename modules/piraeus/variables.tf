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
  description = "Allow-list of node names (`kubernetes.io/hostname`) for every Piraeus workload, on top of `node_selector`: Satellites, CSI node plugin, LINSTOR controller, CSI controller, HA/affinity controllers, NFS server. Empty = every `node_selector` node. List only nodes with DRBD 9 loaded (a Satellite on a node without it cannot attach volumes), and include every node `control_plane_node_selector` may pick, or the controllers stay Pending."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for h in var.node_hostnames : length(trimspace(h)) > 0]) && length(distinct(var.node_hostnames)) == length(var.node_hostnames)
    error_message = "node_hostnames: entries must be non-empty and unique node names."
  }
}

variable "csi_controller_replicas" {
  description = "Replicas of the CSI controller (leader-elected attacher, provisioner, resizer, snapshotter), spread over nodes when more than one. With one, losing its node blocks every attach/detach until Kubernetes evicts it from the dead node (about 5 minutes): an RWO volume cannot move off that node meanwhile. Keep it below the number of nodes the controller may run on (required anti-affinity: a replica without a free node stays Pending)."
  type        = number
  default     = 1

  validation {
    condition     = var.csi_controller_replicas >= 1 && floor(var.csi_controller_replicas) == var.csi_controller_replicas
    error_message = "csi_controller_replicas must be a whole number >= 1."
  }
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
