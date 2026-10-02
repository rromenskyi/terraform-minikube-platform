# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Tenant MySQL setup re-asserts the user's password (`ALTER USER`);
  `CREATE USER IF NOT EXISTS` alone kept an old one.

### Added
- `rate_limits:` component key: per-path Traefik RateLimit middleware on the
  whole-host routes, counted per `CF-Connecting-IP`.

### Changed
- **BREAKING (inputs): removed `redis_default_secret` and `redis_helm_revision`.**
  Per-tenant Redis ACL provisioning moved from a one-shot `redis-setup` Job to
  the declarative `redis-acl-keeper` in `modules/redis`. The project now writes
  a `redis-acl-<ns>` Secret into the Redis namespace (one `ACL SETUSER` line,
  password as a SHA-256 hash — never plaintext) and the keeper re-applies it to
  every Valkey node on a loop, so tenant users survive a Valkey restart / node
  reboot instead of `WRONGPASS`-ing until manual re-run. Migration: drop the
  `redis_default_secret` / `redis_helm_revision` arguments from the module call
  (root no longer wires them).
- **`redis-credentials` gains `WP_REDIS_SELECTIVE_FLUSH=1`.** This Valkey build
  renames `FLUSHDB`/`FLUSHALL` away, so WordPress redis-cache's default flush
  errors with "unknown command" and 500s the site; the env switches the
  object-cache drop-in to selective SCAN+UNLINK-by-prefix flush.

### Added
- **`fallback_errors: false` per component.** Drops the platform-wide
  fallback-error middleware from that component's IngressRoute rules, so
  its own 502/503/504 bodies reach the client instead of the branded HTML
  page. Meant for APIs whose clients parse error bodies. Default `true`
  keeps today's behaviour.
- **Path-scoped routes.** A route key may now be `<host-prefix>/<path>`:
  `"/api": api` routes `<domain>/api` and `<domain>/api/*` to `api`,
  `"www/api/v1": api` does the same for `www.<domain>/api/v1`. The
  component's IngressRoute gains one rule per path —
  `Host(h) && (Path(p) || PathPrefix(p/))`, segment-boundary match, no
  prefix stripping — with an explicit priority (`10000 + len(path)`) so a
  path always wins over a whole-host route on the same host and a longer
  path over a shorter one. Path routes never create a hostname of their
  own: `output.hostnames` lists the host once, attributed to its
  whole-host component. Invalid paths fail at plan time (IngressRoute
  precondition). Keys without a `/` behave exactly as before — existing
  projects plan with no changes.
- **`gcp_wif_service_accounts` — standalone WIF SA + credential-config for
  chart-managed workloads.** Per-env map of k8s SA name →
  `{ gcp_service_account }`. Engine emits a bare `ServiceAccount` plus a
  `<sa>-gcp-wif-credential-config` ConfigMap (same `external_account` shape
  as the per-component `gcp_wif` knob) without owning any Pod — for Argo CD
  helm charts that wire their own pod. Audience reuses
  `gcp_wif_pool_provider_audience`; a plan-time check fails if entries are
  declared while that audience is empty.
- **GCP Workload Identity Federation per-component opt-in.** New variable
  `gcp_wif_pool_provider_audience` (cluster-wide audience string). When
  any component yaml under this project has `gcp_wif.gcp_service_account:
  <email>` set, the engine emits a `<component>-gcp-wif-credential-config`
  ConfigMap in the project namespace with the GCP SDK `external_account`
  shape (audience from the new variable, impersonation URL from the
  component's GCP SA email) and wires `gcp_wif_credential_configmap_name`
  + `gcp_wif_audience` into `modules/component`, which renders the
  projected SA token volume + mounts + GOOGLE_APPLICATION_CREDENTIALS
  env. Plan-time check fails if any component opts in but the audience
  is empty. Components not opted in are unaffected.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
