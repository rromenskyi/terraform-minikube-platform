# Piraeus Datastore (LINSTOR + DRBD + CSI) on the nodes with storage. Values
# in `services.piraeus` (platform.yaml); see modules/piraeus/README.md.
module "piraeus" {
  source = "./modules/piraeus"

  enabled                     = local.platform.services.piraeus.enabled
  namespace                   = local.platform.services.piraeus.namespace
  operator_chart_version      = local.platform.services.piraeus.operator_chart_version
  node_selector               = local.platform.services.piraeus.node_selector
  node_hostnames              = local.platform.services.piraeus.node_hostnames
  control_plane_node_selector = local.platform.services.piraeus.control_plane_node_selector
  csi_controller_replicas     = local.platform.services.piraeus.csi_controller_replicas
  host_network                = local.platform.services.piraeus.host_network
  drbd_loader_mode            = local.platform.services.piraeus.drbd_loader_mode
  storage_pools               = local.platform.services.piraeus.storage_pools
  storage_classes             = local.platform.services.piraeus.storage_classes
  monitoring                  = local.platform.services.piraeus.monitoring
}
