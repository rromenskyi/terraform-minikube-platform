# Changelog

## [Unreleased]

### Added
- `satellite_properties` (LINSTOR node properties by node name) and `storage_classes[].x_replicas_on_different`: e.g. mark the storage nodes `Aux/storage-site` and allow 2 replicas per site, which keeps quorum tiebreakers off the storage nodes (LINSTOR forces the limit to 1 for tiebreakers).
- `controller_properties` (optional): LINSTOR cluster-wide properties via LinstorCluster `spec.properties` (merged over the operator's defaults), e.g. a higher DRBD resync cap `DrbdOptions/PeerDevice/c-max-rate`.
- `nfs_server_node_hostnames` (optional): run the NFS server (ReadWriteMany exports) only on the listed nodes, e.g. those with the data copies, so an export never lands on a diskless node.
- `storage_classes[].mount_options` (optional): mount options of the class, e.g. `soft`/`timeo`/`retrans` for ReadWriteMany (NFS-exported) volumes.
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
