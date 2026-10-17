# piraeus

Installs [Piraeus Datastore](https://piraeus.io): the Piraeus operator
(Helm chart `oci://ghcr.io/piraeusdatastore/piraeus-operator/piraeus`), a
`LinstorCluster` (LINSTOR controller, one Satellite per selected node, the
LINSTOR CSI driver), Satellite configurations and StorageClasses. Volumes are
DRBD devices on thin zvols of an existing ZFS pool, replicated to
`placement_count` nodes.

## Configuration (`platform.yaml`)

```yaml
services:
  piraeus:
    enabled: true
    node_selector: { topology.kubernetes.io/zone: home }        # Satellites + CSI node plugin
    control_plane_node_selector: { topology.kubernetes.io/zone: home }
    # host_network: true          # DRBD over the nodes' own addresses/routes
    # drbd_loader_mode: deps_only # DRBD 9 comes from the host (DKMS)
    storage_pools:
      - name: tank
        node_selector: { kubernetes.io/hostname: storage-1 }
        zfs_thin_pool: tank       # existing zpool on those nodes
    storage_classes:
      - name: linstor-tank
        storage_pool: tank
        placement_count: 1        # copies; 2 once a second storage node exists
        # fs_type: ext4, reclaim_policy: Retain, default: false
```

## Requirements on the nodes

- DRBD 9 kernel module loaded (`drbd_loader_mode: deps_only`), or kernel
  headers present for the loader to build it (`drbd_loader_mode: ""`).
- The ZFS pool already exists on the storage nodes.
- With `host_network`, Satellites listen on the host: LINSTOR ports
  3366-3367 and DRBD ports 7000-7999 must be reachable between the nodes.

Only pods on `node_selector` nodes can attach Piraeus volumes; nodes without
a storage pool attach them diskless over DRBD.
