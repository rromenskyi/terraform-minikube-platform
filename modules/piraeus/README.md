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

Only pods on `node_selector` (and `node_hostnames`, if set) nodes can attach
Piraeus volumes; nodes without a storage pool attach them diskless over DRBD.

Every node with a Satellite needs DRBD 9 loaded: on a node without it the
attach fails (`ControllerPublishVolume ... 404 Not Found`) and the pod stays
in `Init`. When nodes join by label (a zone label every node gets), list the
DRBD-ready ones in `node_hostnames` so a new node gets no Satellite and no
CSI node plugin until it has DRBD. This does not steer the scheduler by
itself: with remote volume access the PVs carry no node affinity, so pods
with Piraeus volumes need their own node affinity (e.g. on the
`linbit.com/hostname` label the CSI node plugin puts on its nodes).

`node_hostnames` is applied as LinstorCluster `nodeAffinity` to every
Piraeus workload (Satellites, CSI node plugin, LINSTOR and CSI controllers,
HA/affinity controllers, NFS server): include the nodes
`control_plane_node_selector` may pick, or the controllers stay Pending.
Setting or changing it rolls those workloads once; mounted volumes keep
working, attach/detach and provisioning pause meanwhile.

Node failure: the HA controller (operator default) force-deletes a pod with a
DRBD volume on a node that dropped out of the DRBD connections and deletes its
VolumeAttachment; the CSI controller's attacher then detaches it, and the pod
starts elsewhere. With one CSI controller replica on the failed node nothing
detaches until Kubernetes evicts that replica (about 5 minutes): set
`csi_controller_replicas: 2` (leader-elected, one per node; keep it below the
number of nodes the controller may run on). Changing it rolls the controller.

ReadWriteMany claims are NFS exports: DRBD Reactor in the NFS server pod
promotes the volume and starts NFS-Ganesha on whichever node wins, a diskless
one included (then every read crosses that node's link twice). Set
`nfs_server_node_hostnames` to the nodes with the storage pools (at least two)
to keep exports on a local copy, as long as the volumes' copies live there.
Changing it rolls the NFS server pods and moves live exports off removed
nodes: clients get I/O errors (soft mounts) or stall (hard) until another node
has promoted the volume and NFS-Ganesha has finished its grace period. Check
afterwards that no removed node is still DRBD Primary for an export.

Quorum tiebreakers: with two copies LINSTOR adds a diskless tiebreaker on
some other node, by default any node, storage nodes included. To keep them on
dedicated witness nodes, mark the storage nodes and cap replicas per mark:

    satellite_properties:
      storage-site: { node_hostnames: [storage-1, storage-2], properties: { Aux/storage-site: storage } }
    storage_classes:
      - { name: ..., placement_count: 2, x_replicas_on_different: { Aux/storage-site: 2 } }

Two copies may still sit on storage nodes; a tiebreaker (LINSTOR forces the
limit to 1 for it) cannot. Consumer pods attach on any node as before. The
class parameter reaches the resource group when a volume is created, so for
existing groups set it once with `linstor rg modify <group>
--x-replicas-on-different Aux/storage-site 2`.

Removing a node from the list deletes its Satellite: first move the pods
that use Piraeus volumes there and, if it holds replicas, evacuate them
(`linstor node evacuate`); the LINSTOR node record may stay behind.
