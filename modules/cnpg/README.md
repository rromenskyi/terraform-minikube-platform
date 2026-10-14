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
3. **Point clients at the cluster.** With the source's own Service, use
   `primary_selector` as its selector (`modules/postgres` `service_selector`).
4. **Roll back.** Restore the old selector, then run `mode = "thaw"`. Writes
   made to the cluster in between stay there.

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
