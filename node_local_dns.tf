# NodeLocal DNSCache (modules/node-local-dns): a DNS cache on every node in
# front of the cluster's CoreDNS, under `services.node_local_dns` in the
# gitignored `config/platform.yaml`.
#
# Names outside the cluster domain go through CoreDNS as well, so the
# `coredns-custom` host overrides and zone forwarders (coredns_overrides.tf)
# keep applying.

data "kubernetes_service_v1" "kube_dns" {
  for_each = local.platform.services.node_local_dns.enabled ? toset(["enabled"]) : toset([])

  metadata {
    name      = "kube-dns"
    namespace = "kube-system"
  }
}

module "node_local_dns" {
  source = "./modules/node-local-dns"

  enabled        = local.platform.services.node_local_dns.enabled
  cluster_dns_ip = one([for s in data.kubernetes_service_v1.kube_dns : s.spec[0].cluster_ip])
  serve_stale    = local.platform.services.node_local_dns.serve_stale
  node_selector  = local.platform.services.node_local_dns.node_selector
}
