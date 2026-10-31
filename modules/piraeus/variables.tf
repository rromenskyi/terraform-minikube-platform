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

variable "nfs_server_node_hostnames" {
  description = "Nodes (`kubernetes.io/hostname`) the NFS server (DRBD Reactor + NFS-Ganesha, serving ReadWriteMany claims) runs on. The export comes up on whichever of its nodes promotes the volume first, so list the nodes holding the data copies: the export then reads a local copy (as long as the volumes' copies are on these nodes) and moves to another listed node on failure, instead of landing on a diskless node and pulling every read over its link. List at least two for failover. Must be a subset of `node_hostnames` when that is set: this list replaces its node affinity for the NFS server (`node_selector` still applies on top). Empty = the operator's default placement."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.node_hostnames) == 0 || alltrue([for h in var.nfs_server_node_hostnames : contains(var.node_hostnames, h)])
    error_message = "nfs_server_node_hostnames must be a subset of node_hostnames."
  }
}

variable "controller_properties" {
  description = "LINSTOR controller (cluster-wide) properties, name => value, set through LinstorCluster `spec.properties` and merged over the operator's defaults. Inherited by every resource unless a resource group or resource overrides them, e.g. `DrbdOptions/PeerDevice/c-max-rate` (KiB/s; DRBD's default 102400 caps a resync at ~100 MiB/s)."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "satellite_properties" {
  description = "LINSTOR node properties by node name: key => { node_hostnames, properties (name => value) }, one LinstorSatelliteConfiguration each. E.g. an `Aux/...` property on the storage nodes for `storage_classes[].x_replicas_on_different`. Do not use the `Aux/topology/` prefix (the CSI driver reads those as topology segments)."
  type = map(object({
    node_hostnames = list(string)
    properties     = map(string)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for s in values(var.satellite_properties) : length(s.node_hostnames) > 0 && alltrue([for k in keys(s.properties) : !startswith(k, "Aux/topology/")])])
    error_message = "satellite_properties: each entry needs node_hostnames; property names must not start with Aux/topology/."
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
      - x_replicas_on_different: node property => max replicas of a volume on
        nodes sharing one value of it (LINSTOR `--x-replicas-on-different`,
        applied to the class's resource group when a volume is created).
        LINSTOR forces it to 1 when placing a quorum tiebreaker, so e.g.
        { "Aux/storage-site" = 2 } with that property only on the storage
        nodes keeps 2 copies there and every tiebreaker on the other nodes.
        Changing it replaces the class.
      - mount_options: passed to mount as is. ReadWriteMany claims on a
        class are NFS exports (the operator's NFS server), so e.g. `soft`,
        `timeo` (deciseconds), `retrans` there make an unreachable server
        an I/O error after the retries (tens of seconds; NFS recovery after
        a failover can add more) instead of a hung process. NFS-only
        options break ReadWriteOnce (block) mounts: keep such a class for
        RWX claims. Soft mounts can fail an operation the server did
        complete, so only for data that may be lost or verified. Changing
        the options replaces the class; existing mounts keep theirs until
        their pods restart.
      - properties: LINSTOR properties set on the class's resource group
        (CSI parameters `property.linstor.csi.linbit.com/<key>`), e.g.
        { "DrbdOptions/Net/protocol" = "A" } for asynchronous replication of
        volumes whose last writes may be lost. Like x_replicas_on_different
        they reach the group when a volume is created, and only as additions:
        the CSI driver refuses to provision when the group already holds a
        different value, and keeps a property removed from the class. Change
        or remove one on the group itself (README). Properties belong to the
        group, so give such a class its own named resource_group (it outlives
        the class, and every volume of the group inherits them). They are
        readable by anyone who can read StorageClasses: no secrets. Changing
        them replaces the class.
  EOT
  type = list(object({
    name                    = string
    storage_pool            = string
    placement_count         = optional(number, 1)
    fs_type                 = optional(string, "ext4")
    reclaim_policy          = optional(string, "Retain")
    default                 = optional(bool, false)
    resource_group          = optional(string, "")
    mount_options           = optional(list(string), [])
    x_replicas_on_different = optional(map(number), {})
    properties              = optional(map(string), {})
  }))
  default = []

  validation {
    condition     = alltrue(flatten([for sc in var.storage_classes : [for v in values(sc.x_replicas_on_different) : v >= 1 && floor(v) == v]]))
    error_message = "storage_classes[].x_replicas_on_different: values must be whole numbers >= 1."
  }

  validation {
    condition     = alltrue(flatten([for sc in var.storage_classes : [for k, v in sc.properties : can(regex("^[^/]+(/[^/]+)+$", k)) && v != ""]]))
    error_message = "storage_classes[].properties: keys are full LINSTOR property names (e.g. DrbdOptions/Net/protocol), values non-empty."
  }

  validation {
    condition     = alltrue([for sc in var.storage_classes : length(sc.properties) == 0 || sc.resource_group != ""])
    error_message = "storage_classes[].properties need a named resource_group: without one the CSI driver derives the group name from them."
  }

  validation {
    condition = alltrue([for sc in var.storage_classes : alltrue([
      for other in var.storage_classes : other.properties == sc.properties
      if sc.resource_group != "" && other.resource_group == sc.resource_group
    ])])
    error_message = "storage_classes[].properties: classes sharing a resource_group must declare the same properties (they are the group's)."
  }
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
