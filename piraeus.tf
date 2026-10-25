# Piraeus Datastore (LINSTOR + DRBD + CSI) on the nodes with storage. Values
# in `services.piraeus` (platform.yaml); see modules/piraeus/README.md.

# Node lists of the Piraeus settings may name node pools (node_pools.tf)
# instead of hosts: `node_hostname_pools`, `nfs_server_node_pools` and
# `satellite_properties.<key>.node_pools` expand to the pools' members,
# merged with any host names given directly. Sorted, so the rendered lists
# do not churn with map order.
locals {
  _piraeus = local.platform.services.piraeus
  _pool_members = {
    for pool, p in local.platform.node_pools : pool => try(p.nodes, [])
  }
  piraeus_node_hostnames = sort(distinct(concat(
    local._piraeus.node_hostnames,
    flatten([for pool in local._piraeus.node_hostname_pools : local._pool_members[pool]]),
  )))
  piraeus_nfs_server_node_hostnames = sort(distinct(concat(
    local._piraeus.nfs_server_node_hostnames,
    flatten([for pool in local._piraeus.nfs_server_node_pools : local._pool_members[pool]]),
  )))
  piraeus_satellite_properties = {
    for k, s in local._piraeus.satellite_properties : k => {
      node_hostnames = sort(distinct(concat(
        try(s.node_hostnames, []),
        flatten([for pool in try(s.node_pools, []) : local._pool_members[pool]]),
      )))
      properties = s.properties
    }
  }
}

module "piraeus" {
  source = "./modules/piraeus"

  enabled                     = local.platform.services.piraeus.enabled
  namespace                   = local.platform.services.piraeus.namespace
  operator_chart_version      = local.platform.services.piraeus.operator_chart_version
  node_selector               = local.platform.services.piraeus.node_selector
  node_hostnames              = local.piraeus_node_hostnames
  control_plane_node_selector = local.platform.services.piraeus.control_plane_node_selector
  csi_controller_replicas     = local.platform.services.piraeus.csi_controller_replicas
  satellite_properties        = local.piraeus_satellite_properties
  nfs_server_node_hostnames   = local.piraeus_nfs_server_node_hostnames
  controller_properties       = local.platform.services.piraeus.controller_properties
  host_network                = local.platform.services.piraeus.host_network
  drbd_loader_mode            = local.platform.services.piraeus.drbd_loader_mode
  storage_pools               = local.platform.services.piraeus.storage_pools
  storage_classes             = local.platform.services.piraeus.storage_classes
  monitoring                  = local.platform.services.piraeus.monitoring
}
