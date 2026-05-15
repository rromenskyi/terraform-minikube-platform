# seafile

Single-pod Seafile community edition deployment — file storage with
library-based sync, OIDC SSO via Zitadel, behind the platform's
Traefik tunnel.

## Shape

Upstream Docker image `seafileltd/seafile-mc:13.x` (all-in-one
bundle: Seahub Django UI + ccnet + fileserver + memcached binary,
Redis is the canonical cache backend since Seafile 13). One
Deployment, one PVC mounted at `/shared`, one IngressRoute splitting
Seahub from the raw blob fileserver by path.

## External dependencies (pre-existing platform services)

- **MySQL** — Seafile 13 CE is MySQL-only (Postgres unsupported
  upstream). Engine pre-creates `ccnet_db`, `seafile_db`,
  `seahub_db` on the shared instance via a one-shot setup Job using
  the cluster's MySQL root credential. Drops a scoped `seafile` user
  with privileges on those three DBs only.
- **Redis** — cache backend. Single shared instance, auth-less
  (cluster trust boundary). Connection over plain TCP to the
  cluster Service.
- **Longhorn** — `/shared` PVC StorageClass (default). Operator can
  override via `var.storage_class`.
- **Zitadel** — OIDC IdP. Caller wires a Zitadel app via
  `modules/zitadel-app` and passes the resulting client_id /
  client_secret in. Empty disables OIDC and falls back to local
  auth via the bootstrap admin.

## Operator-driven knobs

`config/platform.yaml`:

```yaml
services:
  seafile:
    enabled: true
    external_hostname: cloud.example.com
    admin_email: operator@example.com
    storage_size: 100Gi
    # node_selector: { workload-tier: stateful }
    # tolerations: [...]
```

After first apply, the bootstrap admin password is surfaced via
`terraform output -raw seafile_admin_password` — operator logs into
Seahub once with that, then rotates the password through the UI.
SSO becomes the canonical login path; the admin password is only a
break-glass for OIDC outages.

## Lifecycle

- **First-boot init**: container's bootstrap script reads `INIT_*`
  env vars, lays down config files in `/shared/seafile/conf/`,
  populates the MySQL schema, creates the admin user. ~2-3 minute
  cold start.
- **Subsequent restarts**: `INIT_*` env vars are ignored. Container
  reads the on-disk config + DB.
- **Upgrades**: bump `var.image_tag`. Seafile's Docker entrypoint
  runs schema migrations on start. Take a Longhorn snapshot of the
  PVC before bumping a major version.
- **Recreate strategy**: never two pods at once on the shared PVC
  (Seafile holds open file handles).

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
