# volume-seed

Shared convention for modules that move their data from a hostPath directory
(or an older volume) into a StorageClass volume:

- The app's data lives in the volume's `data/` directory (mounted with subPath
  `data`); `.seeded` marks a finished one-time copy; `lost+found` stays out of
  the app's view.
- On the first start an init container copies the old data in: into
  `.seed-tmp`, renamed to `data/` when complete, so an interrupted copy is
  redone, never taken for a finished one. A `data/` that already holds data
  is never overwritten.
- While seeding, the callers keep their old PV/PVC objects and the seed
  container reads the old data through the old claim (Pod Security
  `baseline` forbids hostPath volumes in a pod spec; Kubernetes keeps a
  claim that a pod still uses, and Terraform would delete it before switching
  the workload over). Clearing the seed setting drops them once unused.

Used by `component`, `mysql`, `stalwart`, `roundcube`, `seafile` through their
`storage_class` and `storage_seed_*` variables.

## Clearing the seed setting (after the move)

Terraform deletes the old PV/PVC objects *before* it updates the workloads,
and Kubernetes keeps a claim while a pod mounts it (the seed container does).
Without help the apply stalls, the claims go `Terminating`, and pods
recreated by the old ReplicaSet/StatefulSet stay `Pending` on a claim that is
gone. To clear the seed without an outage:

1. Before the apply, scale each affected workload to 0 (nothing mounts the
   old claims any more).
2. Apply: the old claims are deleted at once, the workloads are updated.
3. Scale back up; the pods start on the new volumes only.

A StatefulSet whose pod is stuck `Pending` on the old spec keeps it after the
update: delete that pod once so it is recreated from the new spec. The old
data (hostPath directories, a `Retain` volume) stays where it was; remove it
when the new volumes and their backups are verified.
