# CoreDNS custom drop-ins — host overrides + zone forwarders.
#
# k3s ships CoreDNS pre-wired to import `/etc/coredns/custom/*.server`
# files as additional top-level server blocks (separate zones), and
# `/etc/coredns/custom/*.override` files imported INSIDE the default
# `.:53 {}` block. We use `.server` here because the main `.:53` block
# already declares one `hosts` plugin call (for NodeHosts), and CoreDNS
# rejects a second `hosts` invocation in the same server block at
# startup. A per-host server block in its own zone scope sidesteps
# that.
#
# Two knobs, both default empty:
#
#   services.coredns.host_overrides   — static A records inside cluster.
#   services.coredns.zone_forwarders  — delegate a zone to an upstream DNS.
#
# Either one being non-empty triggers the ConfigMap; both can populate
# the same map with their respective `.server` keys.
#
# Operator config shape (`config/platform.yaml`):
#
#   services:
#     coredns:
#       host_overrides:
#         relay.example.com: 10.x.x.x
#       zone_forwarders:
#         foo.internal: 10.0.0.1     # zone → upstream DNS resolver IP
#
# CoreDNS does NOT auto-reload custom imports on file change — after
# editing the operator config and applying, the operator must run
# `kubectl rollout restart -n kube-system deploy/coredns` to pick up
# the new server blocks.

locals {
  _coredns_custom_enabled = (
    length(local.platform.services.coredns.host_overrides) > 0 ||
    length(local.platform.services.coredns.zone_forwarders) > 0
  )

  _coredns_custom_instances = local._coredns_custom_enabled ? toset(["enabled"]) : toset([])
}

resource "kubernetes_config_map_v1" "coredns_custom_overrides" {
  for_each = local._coredns_custom_instances

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "coredns-custom-overrides"
    })
  }

  # One server block per host (host_overrides) or per zone
  # (zone_forwarders). CoreDNS routes queries for the named zone to
  # the matching block; everything outside falls through to the
  # default `.:53 {}` block (forward chain).
  #
  # `ttl 60` on hosts keeps Pod-side resolver caches short so an IP
  # change propagates within a minute. `cache 30` on forwarders is the
  # conventional short-TTL cache for delegated zones.
  data = merge(
    length(local.platform.services.coredns.host_overrides) > 0 ? {
      "host-overrides.server" = join("\n\n", [
        for host, ip in local.platform.services.coredns.host_overrides :
        <<-BLOCK
          ${host} {
              hosts {
                  ${ip} ${host}
                  ttl 60
                  fallthrough
              }
          }
        BLOCK
      ])
    } : {},
    length(local.platform.services.coredns.zone_forwarders) > 0 ? {
      "zone-forwarders.server" = join("\n\n", [
        for zone, upstream in local.platform.services.coredns.zone_forwarders :
        <<-BLOCK
          ${zone}:53 {
              errors
              cache 30
              forward . ${upstream}
          }
        BLOCK
      ])
    } : {},
  )
}
