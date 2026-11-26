# Targets for the per-project NetworkPolicy presets (`network_policies:` in
# a domain yaml env, see modules/project/network_policies.tf). The engine
# knows where Traefik, monitoring, cluster DNS and the shared Postgres run;
# the operator config adds what only it knows (`network_policies:` in
# platform.yaml): the mail relay's addresses and extra ranges the internet
# preset must not reach (e.g. the site's own public addresses).
locals {
  network_policy_targets = {
    traefik_namespace    = "ingress-controller"
    monitoring_namespace = "monitoring"
    postgres = local.postgres_on && local.postgres_engine == "cnpg" ? {
      namespace  = local.postgres.namespace
      pod_labels = { "cnpg.io/cluster" = local.cnpg.name }
    } : null
    # NodeLocal DNSCache answers on the node itself (its local IP and the
    # kube-dns ClusterIP, no DNAT to a CoreDNS pod), so the `dns` preset
    # also allows those addresses, as KEP-1024 advises for NetworkPolicy.
    dns_cidrs = local.platform.services.node_local_dns.enabled ? [
      "${module.node_local_dns.local_ip}/32",
      "${one([for s in data.kubernetes_service_v1.kube_dns : s.spec[0].cluster_ip])}/32",
    ] : []
    mail_relay_cidrs = try(local.platform.network_policies.mail_relay_cidrs, [])
    internet_except = concat(
      ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8"],
      try(local.platform.network_policies.internet_except, []),
    )
  }
}
