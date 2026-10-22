# Changelog

## [Unreleased]

### Added
- `csi_controller_replicas` (default 1): run the CSI controller with several leader-elected replicas on different nodes, so attach/detach keeps working when the node with the active one dies (with one replica an RWO volume could not move off a dead node until the replica was evicted, ~5 min).
- `node_hostnames` (optional): allow-list of node names for all Piraeus workloads (Satellites, CSI node plugin, controllers), on top of `node_selector`, so a node that joins without DRBD 9 gets no Satellite. Include the control-plane nodes.
- `storage_pools[].key` (optional, defaults to `name`): declare one LINSTOR pool name on several nodes with different selectors. The pool name in LINSTOR is always `name`; existing entries keep their key and are not recreated.
- `monitoring`: PodMonitors for the LINSTOR controller and the Satellites'
  drbd-reactor, alerts on LINSTOR (controller, satellites, storage pools)
  and DRBD (connections, lost backing disk, suspended I/O, quorum, out of
  sync).
- `storage_classes[].resource_group`: named LINSTOR resource group.
- `storage_pools[].zfs_thin_pool` documented as a pool or a dataset.
- Module: Piraeus operator 2.12.0 (Helm, CRDs), LinstorCluster with node
  selection, Satellite host networking, DRBD loader mode, ZFS thin storage
  pools, StorageClasses.
