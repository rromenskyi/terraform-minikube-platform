# Additional LoadBalancer Service(s) pointing at the existing Traefik
# chart's pods, one per MetalLB pool the operator wants exposed.
#
# Why this exists: the platform's Traefik (terraform-k8s-addons) is
# `traefik_service_type = "ClusterIP"` — it's reachable only through
# in-cluster DNS today. The Cloudflare Tunnel chain handles every
# public hostname (cloudflared → ClusterIP). When the operator wants
# a hostname served WITHOUT going through CF Tunnel — direct A-record
# straight to a node's public IP — we need Traefik to be reachable on
# that IP. Instead of running a second Traefik (CRD-watcher collision
# with the existing one + IngressClass migration for every existing
# IngressRoute), we just add MORE Service objects with the same
# selector pointing at the same pods.
#
# Tenant-facing contract:
#   - DNS A-record → one of the IPs in `services.traefik_public.pools`
#   - IngressRoute in the tenant namespace matching `Host(<that-fqdn>)`
#   - That's it. No `ingressClassName`, no MetalLB annotations on the
#     tenant Service, no chart-side knobs. Same Traefik instance that
#     serves CF Tunnel traffic also serves direct-IP traffic — the
#     decision is at DNS, not at Traefik.
#
# `allow-shared-ip` is set per-pool with the pool name as the sharing
# key, so a future SipMesh / other chart Service that needs the same
# IP for its own ports (e.g. SIP 5160/5061) can share by adding
# `metallb.io/allow-shared-ip: <pool-name>` to its own Service and
# claiming non-overlapping ports. No engine change needed for the
# share to start working.

resource "kubernetes_service_v1" "traefik_public" {
  for_each = local.platform.services.traefik_public.enabled ? local.platform.services.traefik_public.pools : {}

  metadata {
    name      = "traefik-public-${each.key}"
    namespace = "ingress-controller"
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "traefik-public"
      "platform.local/pool"          = each.key
    })
    annotations = {
      "metallb.io/address-pool"    = each.key
      "metallb.io/loadBalancerIPs" = each.value
      # Sharing key = pool name. Future Services on the same IP just
      # add the same annotation + claim non-overlapping ports — no
      # engine-side change to enable.
      "metallb.io/allow-shared-ip" = each.key
    }
  }

  spec {
    type = "LoadBalancer"
    # `Local` preserves the real client source IP (no SNAT to node IP)
    # — required so tenant Services that SHARE this VIP and need source
    # IP (SIP/RTP telephony) can co-own the address: MetalLB only lets
    # Services share an IP when their externalTrafficPolicy matches, so
    # a `Cluster` Traefik here would block a `Local` SIP Service from
    # sharing. Safe because Traefik runs as a DaemonSet (one pod on
    # every node, including each pool's MetalLB-announcer node), so
    # `Local` never blackholes. Bonus: Traefik now sees real client
    # IPs in its access logs / rate-limit / forwarded-for chain
    # instead of the SNAT'd node IP.
    external_traffic_policy = "Local"

    # Match the existing Traefik chart's pod labels — both Services
    # (chart-bundled ClusterIP + this engine-emitted LoadBalancer)
    # target the same pods.
    selector = {
      "app.kubernetes.io/instance" = "traefik-ingress-controller"
      "app.kubernetes.io/name"     = "traefik"
    }

    port {
      name        = "web"
      port        = 80
      target_port = "web"
      protocol    = "TCP"
    }
    port {
      name        = "websecure"
      port        = 443
      target_port = "websecure"
      protocol    = "TCP"
    }
  }

  # MetalLB stamps `metallb.io/ip-allocated-from-pool` onto the Service at
  # runtime (its own bookkeeping). It's not in the annotations we declare, so
  # without this the provider wants to strip it on every apply — perpetual
  # no-op drift. Ignore just that one MetalLB-owned key.
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["metallb.io/ip-allocated-from-pool"],
    ]
  }
}

output "traefik_public_endpoints" {
  description = "Map of MetalLB pool name → public IP where Traefik also listens. Reference-only — DNS records pointing here should be unproxied A-records (CF Tunnel is the parallel path, not this one)."
  value = {
    for k, v in local.platform.services.traefik_public.pools :
    k => v if local.platform.services.traefik_public.enabled
  }
}
