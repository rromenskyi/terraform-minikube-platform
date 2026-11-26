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
    mail_relay_cidrs = try(local.platform.network_policies.mail_relay_cidrs, [])
    internet_except = concat(
      ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16", "127.0.0.0/8"],
      try(local.platform.network_policies.internet_except, []),
    )
  }
}
