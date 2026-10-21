# Changelog

## [Unreleased]

### Added
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
