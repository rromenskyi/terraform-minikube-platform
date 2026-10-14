# node-local-dns

[NodeLocal DNSCache](https://kubernetes.io/docs/tasks/administer-cluster/nodelocaldns/)
(KEP-1024): a DNS cache on every node, in front of the cluster's CoreDNS.

## Shape

- **Interception.** A DaemonSet in the host network binds `local_ip`
  (169.254.20.10) and the cluster DNS Service address (`cluster_dns_ip`) on a
  dummy interface of each node, with NOTRACK rules. Pods' queries to the
  cluster DNS address are answered on their own node; the kubelet's
  `--cluster-dns` stays as it is. This needs kube-proxy in iptables mode.
- **Upstream.** Misses go to the CoreDNS pods through the `kube-dns-upstream`
  Service (`cluster_dns_selector`).
  - With `external_via_cluster_dns` (default), names outside the cluster
    domain go there too. CoreDNS rules for outside names, such as host
    overrides and forwarded zones in a `coredns-custom` ConfigMap, keep
    applying.
  - With it off, those names go to the node's resolvers (the upstream
    default) and bypass such rules.
- **Resilience.**
  - `serve_stale` answers from expired entries while refreshing, so names
    keep resolving through a short loss of CoreDNS or of the network to it.
  - On a clean stop the cache removes its rules, and queries fall back to the
    cluster DNS Service. A crash leaves them in place until the DaemonSet
    restarts it.
- **Placement.** It tolerates every taint, so every node gets a cache.
  `node_selector` limits it, e.g. to one node while introducing it: a new
  DaemonSet starts everywhere at once. Updates roll one node at a time.
- **Metrics.** A PodMonitor for CoreDNS metrics on port 9253.

## Usage

```hcl
data "kubernetes_service_v1" "kube_dns" {
  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

module "node_local_dns" {
  source = "./modules/node-local-dns"

  enabled        = true
  cluster_dns_ip = data.kubernetes_service_v1.kube_dns.spec[0].cluster_ip
}
```

## Inputs and outputs

See `variables.tf` and `outputs.tf`.
