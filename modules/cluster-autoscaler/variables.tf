variable "context" {
  description = "Serialised parent context from `terraform-null-label` (root passes `module.platform_label.context`). Null = a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to run cluster-autoscaler with the plugpool sidecar. False creates nothing. Turning it off later leaves the machines as they are: one that is powered off stays off until it is switched on by hand."
  type        = bool
  default     = false
  nullable    = false
}

variable "namespace" {
  description = "Namespace of cluster-autoscaler, plugpool and the one-shot poweroff pods. The module owns it and labels it Pod Security `privileged` (the poweroff pods run privileged with host PID). Do not put a ResourceQuota on it: the poweroff pods use priority class `system-node-critical`."
  type        = string
  default     = "cluster-autoscaler"
  nullable    = false
}

variable "ca_image" {
  description = "cluster-autoscaler image (externalgrpc cloud provider)."
  type        = string
  default     = "registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.1@sha256:461388d03eb5b55db58941ee7a81d9a619dd15302b01cbab9f5a9946715994b4"
  nullable    = false
}

variable "plugpool_image" {
  description = "plugpool image: the externalgrpc provider that powers machines through ESPHome smart plugs (github.com/ipsupport-llc/plugpool)."
  type        = string
  default     = "ghcr.io/ipsupport-llc/plugpool:0.1.0@sha256:cab8356b58c7d2aff7dc7827caaeddd4c45fa8be15e646bbc2feaa2835bcf151"
  nullable    = false
}

variable "poweroff_image" {
  description = "Image of the one-shot poweroff pod; it must provide `nsenter`."
  type        = string
  default     = "busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
  nullable    = false
}

variable "node_groups" {
  description = <<-EOT
    Power-managed node groups, one cluster-autoscaler node group each:
      - id, min_size, max_size (at most the number of nodes)
      - template: what a new machine of the group offers, for scale-up from
        zero (cpu, memory, pods, labels — include the label workloads select
        the group by — and taints). Do not claim more than the machine's
        allocatable: cluster-autoscaler would power machines on for pods
        that do not fit.
      - nodes: the Kubernetes node name of each machine, its plug's ESPHome
        web server URL and the switch entity driving the relay. One plug per
        machine.
  EOT
  type = list(object({
    id       = string
    min_size = number
    max_size = number
    template = object({
      cpu    = string
      memory = string
      pods   = optional(string, "110")
      labels = optional(map(string), {})
      taints = optional(list(object({
        key    = string
        value  = optional(string)
        effect = string
      })), [])
    })
    nodes = list(object({
      name        = string
      plug_url    = string
      plug_switch = string
    }))
  }))
  default  = []
  nullable = false

  validation {
    condition     = length(var.node_groups) == length(distinct([for g in var.node_groups : g.id]))
    error_message = "node_groups: ids must be unique."
  }
  validation {
    condition     = alltrue([for g in var.node_groups : g.min_size >= 0 && g.min_size <= g.max_size && g.max_size <= length(g.nodes) && floor(g.min_size) == g.min_size && floor(g.max_size) == g.max_size])
    error_message = "node_groups: need whole numbers 0 <= min_size <= max_size <= number of nodes."
  }
  validation {
    condition     = alltrue(flatten([for g in var.node_groups : [for n in g.nodes : can(regex("^https?://[^/]+", n.plug_url)) && n.plug_switch != ""]]))
    error_message = "node_groups: every node needs an http(s) plug_url and a plug_switch."
  }
  validation {
    condition = length(flatten([for g in var.node_groups : g.nodes])) == length(distinct(flatten([
      for g in var.node_groups : [for n in g.nodes : "${lower(trimsuffix(n.plug_url, "/"))}#${n.plug_switch}"]
    ])))
    error_message = "node_groups: two nodes use the same plug; switching it off for one would cut the other."
  }
  validation {
    condition     = length(flatten([for g in var.node_groups : g.nodes])) == length(distinct(flatten([for g in var.node_groups : [for n in g.nodes : n.name]])))
    error_message = "node_groups: a node is listed twice."
  }
}

variable "provider_id_prefix" {
  description = "Node `spec.providerID` = prefix + node name (k3s: `k3s://`). plugpool matches nodes to machines by it."
  type        = string
  default     = "k3s://"
  nullable    = false
}

variable "plug_username" {
  description = "HTTP basic-auth user of the plugs' web servers."
  type        = string
  default     = "admin"
  nullable    = false
}

variable "vault_path" {
  description = "Vault KV v2 path (mount `secret`) holding the plugs' web password under key `password`; synced by the Vault Secrets Operator into Secret `plugpool-plugs`. Required when enabled."
  type        = string
  default     = ""
  nullable    = false
}

variable "vault_auth_role" {
  description = "Vault kubernetes-auth role the sync authenticates with, through a VaultAuth in the namespace (a role limited to `vault_path`). Empty = VSO's cluster-default VaultAuth, whose role must then bind this namespace."
  type        = string
  default     = ""
  nullable    = false
}

variable "scale_down_unneeded_time" {
  description = "cluster-autoscaler `--scale-down-unneeded-time`: how long a machine must be unneeded before it is powered off."
  type        = string
  default     = "30m"
  nullable    = false
}

variable "scale_down_delay_after_add" {
  description = "cluster-autoscaler `--scale-down-delay-after-add`: no scale-down this long after a power-on."
  type        = string
  default     = "30m"
  nullable    = false
}

variable "max_node_provision_time" {
  description = "cluster-autoscaler `--max-node-provision-time`: a machine that has not registered this long after its power-on counts as failed; its plug is switched off again."
  type        = string
  default     = "10m"
  nullable    = false
}

variable "node_selector" {
  description = "Node selector of the autoscaler pod. It must keep the pod off every power-managed machine and on a node that can reach the plugs."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "tolerations" {
  description = "Tolerations of the autoscaler pod."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default  = []
  nullable = false
}

variable "monitoring" {
  description = "Scrape cluster-autoscaler's metrics (Service + ServiceMonitor on port 8085). Needs the Prometheus operator CRDs."
  type        = bool
  default     = true
  nullable    = false
}

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects ServiceMonitors by."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
  nullable    = false
}
