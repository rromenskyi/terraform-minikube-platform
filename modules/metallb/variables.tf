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
  default     = "0.15.3"
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

variable "shared_ip_annotations" {
  description = "Map of `<namespace>/<service-name>` → shared-ip key. Engine annotates the listed Service with `metallb.io/allow-shared-ip: <key>` so MetalLB legalises sharing one VIP across multiple Services with non-conflicting port/protocol pairs (e.g. Traefik on TCP 80/443 and a SIP proxy on UDP 5160). Both Services must carry the SAME key AND the same `externalTrafficPolicy` (MetalLB rejects sharing across mismatched policies); the engine writes the annotation server-side without touching the Service's other fields, so a chart-managed Service (Helm, ArgoCD) keeps its ownership intact. Empty map (default) emits no annotations. Only meaningful when at least one pool's IP is targeted by multiple Services."
  type        = map(string)
  default     = {}
  validation {
    condition = alltrue([
      for k, _ in var.shared_ip_annotations : can(regex("^[a-z0-9-]+/[a-z0-9-]+$", k))
    ])
    error_message = "Every `shared_ip_annotations` key must be `<namespace>/<service-name>` (lowercase DNS labels)."
  }
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
