# MetalLB — bare-metal LoadBalancer.
#
# Enables real-IP allocation for `Service type: LoadBalancer` on a
# self-hosted / VPS cluster. L2 mode only (gratuitous ARP); BGP is
# out of scope until the platform spans multi-rack / multi-DC.
#
# Pool layout is operator-driven via `services.metallb.pools` —
# the engine knows nothing about which node owns which IP. Each
# pool's `l2_node_selectors` restricts the speakers that announce
# its VIPs (avoids ARP split-brain when multiple speakers run).
#
# Source-IP preservation requires the consuming Service to set
# `externalTrafficPolicy: Local` AND its backend pod to land on
# the announcing node — see modules/metallb/main.tf for the full
# rationale.

module "metallb" {
  source     = "./modules/metallb"
  depends_on = [module.addons]

  enabled                  = local.platform.services.metallb.enabled
  controller_node_selector = local.platform.services.metallb.controller_node_selector
  controller_tolerations   = local.platform.services.metallb.controller_tolerations
  speaker_node_selector    = local.platform.services.metallb.speaker_node_selector
  speaker_tolerations      = local.platform.services.metallb.speaker_tolerations
  pools                    = local.platform.services.metallb.pools
}

output "metallb_pools" {
  description = "Map of pool name → list of addresses, mirroring the operator-configured pools. Empty when MetalLB is disabled."
  value       = module.metallb.pools
}
