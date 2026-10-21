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
    node_hostnames: [storage-1, worker-1]                      # optional: only these (DRBD 9 loaded)
    control_plane_node_selector: { topology.kubernetes.io/zone: home }
    # host_network: true          # DRBD over the nodes' own addresses/routes
    # drbd_loader_mode: deps_only # DRBD 9 comes from the host (DKMS)
    storage_pools:
      - name: k8s
        node_selector: { kubernetes.io/hostname: storage-1 }
        zfs_thin_pool: tank/k8s   # existing zpool or dataset on those nodes
      # Same pool on a second node: own `key`, same `name`.
      # - { key: k8s-storage-2, name: k8s, node_selector: { kubernetes.io/hostname: storage-2 }, zfs_thin_pool: tank/k8s }
    storage_classes:
      - name: linstor-tank
        storage_pool: k8s
        placement_count: 1        # copies; 2 once a second storage node exists
        resource_group: k8s       # named LINSTOR resource group (else sc-<hash>)
        # fs_type: ext4, reclaim_policy: Retain, default: false
    # monitoring: true            # PodMonitors + LINSTOR/DRBD alerts
```

## Requirements on the nodes

- DRBD 9 kernel module loaded (`drbd_loader_mode: deps_only`), or kernel
  headers present for the loader to build it (`drbd_loader_mode: ""`).
- The ZFS pool (or dataset) already exists on the storage nodes.
- With `host_network`, Satellites listen on the host: LINSTOR ports
  3366-3367 and DRBD ports 7000-7999 must be reachable between the nodes.

More copies later: raise `placement_count` (the StorageClass is replaced;
bound volumes are unaffected), then bring the existing volumes up to it with
`linstor rg modify <group> --place-count 2` and `linstor rg adjust <group>`;
LINSTOR adds the copies online. With a named `resource_group` the CSI driver
keeps the group's settings in line with the StorageClass, so change both.

Only pods on `node_selector` nodes can attach Piraeus volumes; nodes without
a storage pool attach them diskless over DRBD.

Every node with the CSI node plugin needs DRBD 9 loaded: the scheduler puts
pods with Piraeus volumes on any of them, and on a node without DRBD 9 the
attach fails (`ControllerPublishVolume ... 404 Not Found`) and the pod stays
in `Init`. When nodes join by label (a zone label every node gets), list the
DRBD-ready ones in `node_hostnames` so a new node stays out until it has
DRBD. Removing a node from the list while pods there use Piraeus volumes
takes their volumes away: move the pods first.
The operator applies `node_hostnames` (as LinstorCluster `nodeAffinity`) to
the LINSTOR controller and the CSI controller too, so they also run only on
listed nodes; setting or changing it restarts them once (the DRBD data path
is not affected).
