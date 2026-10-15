# cnpg

A highly available PostgreSQL cluster run by the
[CloudNativePG](https://cloudnative-pg.io) operator, with continuous backups
to S3-compatible storage through the
[Barman Cloud plugin](https://github.com/cloudnative-pg/plugin-barman-cloud).

## Shape

- **Operator and plugin.** Both Helm charts land in `operator_namespace`
  (`cnpg-system`). The plugin needs cert-manager. The operator ships its
  Grafana dashboard and a PodMonitor for itself.
- **Cluster.** `instances` Postgres pods: one primary and streaming replicas.
  - **Placement.** Pod anti-affinity is `required` on the hostname, so no two
    instances share a node. `nodes` limits them to the listed hostnames.
  - **Storage.** A node-local StorageClass (`local-path`) per instance: the
    replicas already copy the data.
  - **Failover.** When the primary's node fails, the operator promotes the most
    advanced replica and moves `<name>-rw` to it. A returning node rejoins as a
    replica. The decision goes through the Kubernetes API, so the etcd quorum
    settles it, not the instances.
  - **Synchronous replication** (`synchronous`) uses `dataDurability:
    preferred`. A commit waits until one replica has it while a replica is
    healthy, and writes go on without one.
  - **Data checksums** are on. Postgres verifies every page it reads, which
    catches corruption the storage did not.
  - **Superuser.** The `postgres` superuser stays enabled, with the password
    from `superuser_password`. Its Secret also carries the password as
    `POSTGRES_PASSWORD` for tools that expect the official image's key.
- **Backups**, when `backup_bucket` and `backup_endpoint` are set:
  - every WAL segment is archived;
  - a base backup runs on `backup_schedule` and once right after creation;
  - retention is `backup_retention`.
  - Everything goes under `s3://<bucket>/<backup_prefix>/<name>/`. The
    ObjectStore asks boto3 for checksums only where required, because
    Backblaze B2 rejects the newer ones (plugin issue #393).
- **Alerts.** A PrometheusRule fires:
  - when fewer than `instances` instances are up;
  - when a replica lags more than 5 minutes;
  - with backups on, when WAL archiving fails.

- **Second cluster** (`replica_cluster`, optional): see below.

## Second cluster at another site

`replica_cluster` adds a second Cluster in the same namespace, typically
pinned to nodes at another site (`nodes`, `tolerations`). The two form a
CloudNativePG
[distributed topology](https://cloudnative-pg.io/documentation/current/replica_cluster/#distributed-topology):

- **Who writes.** Both Clusters name the same `primary_cluster` (default: the
  main cluster). The other one is read-only. `service_name` and the `host`
  output follow `primary_cluster`.
- **How it follows.**
  - It starts as a `pg_basebackup` copy.
  - Its designated primary then streams from the primary cluster's `-rw`
    Service over TLS, with the operator's `streaming_replica` certificate.
  - With backups on, the primary cluster's WAL archive is the fallback.
  - Replication is asynchronous: a failover loses what had not arrived
    (seconds while streaming, up to `archive_timeout`, 5 min, from the
    archive).
- **Same identity.** It uses the same superuser Secret, image, parameters
  and backup store. It archives WAL and takes base backups under its own
  name (`s3://<bucket>/<backup_prefix>/<replica name>/`), so it is
  restorable the moment it is promoted.
- **Alerts.** The two clusters get the same alerts. The one that is not the
  primary also gets `CNPGReplicaClusterNotStreaming` when an instance
  lost its WAL receiver for 15 minutes.
- **Requirements.** The operator and the Kubernetes API must survive the
  loss of the main site: an etcd quorum without it, and an operator pod
  that can reschedule there.

### Failover (the primary cluster's site is lost)

1. Set `primary_cluster` to the other cluster and apply. If the former
   primary's site is still partly up (e.g. a bad link rather than an
   outage), stop the writers there first. The same apply demotes it only
   once the operator reaches its instances.
   - The other cluster promotes at once and `service_name` selects its
     primary.
   - The former primary's Cluster now says it is a replica. If its
     instances come back, they demote instead of taking writes.
   - **When Terraform cannot plan** (e.g. a provider talks to a service that
     died with the site), make the same change by hand. Then set
     `primary_cluster` to match, so the next apply is a no-op:

     ```sh
     for c in <main> <replica>; do
       kubectl -n <namespace> patch cluster $c --type merge \
         -p '{"spec":{"replica":{"primary":"<new primary>"}}}'
     done
     kubectl -n <namespace> patch service <service_name> --type merge \
       -p '{"spec":{"selector":{"cnpg.io/cluster":"<new primary>"}}}'
     ```

2. **Rebuild the former primary** once its site is back. It has diverged
   and cannot follow, so recreate it as a copy. The main cluster's
   `bootstrap` switches to `pg_basebackup` from the other cluster as soon
   as it is not the primary, and the second cluster's always is one. Its
   PVCs belong to the Cluster object and go with it, but only after it is
   deleted. A `-replace` would create the new Cluster while the old PVCs,
   with the same names and the diverged data, still exist. So:

   ```sh
   kubectl -n <namespace> delete cluster <former primary> --wait
   kubectl -n <namespace> wait --for=delete pvc -l cnpg.io/cluster=<former primary> --timeout=10m
   terraform apply   # recreates it from the current primary
   ```
3. **Moving back** is the same failover in the other direction. Stop the
   writes first if nothing may be lost, and rebuild the other side after.
   A switchover without rebuilding (CloudNativePG demotion and promotion
   tokens) is not wired in.

## Usage

```hcl
module "cnpg" {
  source = "./modules/cnpg"

  enabled   = true
  namespace = "platform"
  name      = "pg"
  instances = 2
  nodes     = ["node-a", "node-b"]

  superuser_password = random_password.pg.result

  backup_bucket            = "my-backups"
  backup_endpoint          = "https://s3.us-east-005.backblazeb2.com"
  backup_access_key_id     = var.backup_key_id
  backup_secret_access_key = var.backup_key
}
```

Applications connect to `host` (the `<name>-rw` Service). Read-only queries
can go to `ro_host`.

## Moving off another Postgres server

`sync` copies every database and role from another server, keeping the
password hashes, so clients' credentials stay valid:

1. **Rehearsal** (`mode = "rehearsal"`, new `run` id each time): copies while
   the source keeps running and reports how long it takes. The copy is a
   throwaway; row counts may differ because the source takes writes.
2. **Cutover** (`mode = "cutover"`): freezes the source first. Every database
   gets `CONNECTION LIMIT 0` and non-superuser sessions end, so nothing is
   written after the dump starts. Then the Job copies and fails on any
   difference.
3. **Point clients at the cluster.** Give the cluster the source's Service
   name (`service_name`) and Secret name (`superuser_secret_name`). Then move
   those two objects from the source's module to this one in the state
   (`terraform state mv`), so they are updated in place, not recreated.
4. **Roll back.** Move them back, then run `mode = "thaw"`. Writes made to the
   cluster in between stay there.

## Operating

- **Switchover** (planned primary move, e.g. before a node reboot):
  `kubectl cnpg promote -n <namespace> <name> <name>-<N>`.
- **Move an instance to another node.** Change `nodes`, then delete the
  instance's PVC and pod. The operator recreates it on an allowed node and
  clones it from the primary.
- **Restore** goes into a new Cluster with `bootstrap.recovery` from the same
  ObjectStore; see the plugin's documentation.

## Inputs and outputs

See `variables.tf` and `outputs.tf`.
