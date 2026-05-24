# CoreDNS host overrides — drop-in `*.server` ConfigMap.
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
# Engine emits one server block per (hostname, ip) pair declared in
# `services.coredns.host_overrides`. Each block carries a `hosts`
# plugin with the static A record; CoreDNS zone-routes queries for
# that hostname to this block, everything else continues to the
# default `.:53` block.
#
# Use case: in-cluster Pod resolves a public hostname to a private IP
# (e.g. routing outbound mail through a WG-mesh-only relay whose TLS
# cert is issued for the public hostname). DNS public records are
# untouched; only Pods inside this cluster see the override.
#
# Operator config shape (`config/platform.yaml`):
#
#   services:
#     coredns:
#       host_overrides:
#         relay.example.com: 10.x.x.x
#         other.host.example: 10.y.y.y
#
# Empty map (default) → ConfigMap is not emitted, CoreDNS unchanged.

resource "kubernetes_config_map_v1" "coredns_custom_overrides" {
  for_each = length(local.platform.services.coredns.host_overrides) > 0 ? toset(["enabled"]) : toset([])

  metadata {
    name      = "coredns-custom"
    namespace = "kube-system"
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "coredns-custom-overrides"
    })
  }

  # One server block per host. CoreDNS routes queries for the named
  # zone (the hostname) to this block; everything outside the zone
  # falls through to the default `.:53 {}` block (forward chain).
  # `ttl 60` keeps Pod-side resolver caches short so an IP change
  # propagates within a minute. CoreDNS does NOT auto-reload custom
  # imports on file change — operator must
  # `kubectl rollout restart -n kube-system deploy/coredns` after
  # editing the override map.
  data = {
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
  }
}
