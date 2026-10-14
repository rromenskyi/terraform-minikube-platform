variable "enabled" {
  description = "Install the node-local DNS cache. False collapses every resource to zero."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace of the cluster DNS (CoreDNS) Service; the cache and its `kube-dns-upstream` Service land there."
  type        = string
  default     = "kube-system"
}

variable "image" {
  description = "NodeLocal DNSCache image (CoreDNS plus the node setup that intercepts the cluster DNS address)."
  type        = string
  default     = "registry.k8s.io/dns/k8s-dns-node-cache:1.27.1"
}

variable "cluster_dns_ip" {
  description = "Required when enabled. ClusterIP of the cluster DNS Service (the address the kubelet puts into pods' resolv.conf). The cache also binds it on every node, so pods reach the cache without any kubelet change; this works with kube-proxy in iptables mode."
  type        = string
  default     = null

  validation {
    condition     = var.cluster_dns_ip == null || can(cidrhost("${var.cluster_dns_ip}/32", 0))
    error_message = "cluster_dns_ip must be an IPv4 address."
  }
}

variable "cluster_dns_selector" {
  description = "Pod selector of the cluster DNS (CoreDNS) pods; the `kube-dns-upstream` Service the cache forwards to selects them."
  type        = map(string)
  default     = { "k8s-app" = "kube-dns" }
}

variable "local_ip" {
  description = "Link-local address the cache binds on every node next to `cluster_dns_ip`."
  type        = string
  default     = "169.254.20.10"
}

variable "cluster_domain" {
  description = "Cluster DNS domain."
  type        = string
  default     = "cluster.local"
}

variable "external_via_cluster_dns" {
  description = "Send names outside the cluster domain through the cluster DNS as well, instead of straight to the node's resolvers (the upstream default). Keep it on when the cluster DNS has rules of its own for outside names (host overrides, forwarded zones): with it off, the cache bypasses them."
  type        = bool
  default     = true
}

variable "serve_stale" {
  description = "How long the cache may answer from expired entries while it refreshes them (CoreDNS `cache serve_stale`). Keeps names resolving through a short loss of the cluster DNS. Empty = off."
  type        = string
  default     = "1h"
}

variable "resources" {
  description = "Requests and limits of the cache container."
  type = object({
    requests = optional(map(string), { cpu = "25m", memory = "16Mi" })
    limits   = optional(map(string), { memory = "128Mi" })
  })
  default = {}
}

variable "prometheus_selector_labels" {
  description = "Labels the cluster's Prometheus selects PodMonitors by."
  type        = map(string)
  default     = { release = "kube-prometheus-stack" }
}

variable "node_selector" {
  description = "Limit the cache to matching nodes, e.g. one node first when introducing it (a new DaemonSet starts on every node at once). Empty = every node."
  type        = map(string)
  default     = {}
}
