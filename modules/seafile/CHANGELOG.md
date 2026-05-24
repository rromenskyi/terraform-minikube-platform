# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **First-boot bootstrap conflict — `seahub_settings.py` no longer
  mounted via ConfigMap subPath.** Seafile's first-boot installer
  WRITES `seahub_settings.py` to populate DB credentials + Django
  `SECRET_KEY` + other runtime values; mounting a ConfigMap over
  that path makes it read-only and bootstrap fails on
  `OSError: [Errno 30] Read-only file system`. ConfigMap +
  subPath volume_mount + `checksum/seahub-settings` pod annotation
  removed. OIDC + reverse-proxy URL config now lives outside the
  engine — operator configures via Seahub admin UI on first login
  (bootstrap super-user password remains available via
  `terraform output -raw <module>_admin_password`). Canonical fix
  is a postStart hook that APPENDS our config block after bootstrap
  settles; deferred as a follow-up — current shape is workable for
  single-operator deployments where one-time UI configuration is
  acceptable.
- **Readiness probe switched from HTTP GET to TCP socket.** Seahub's
  `/` returns 302 to `/accounts/login/`, kubelet follows the redirect,
  the login page render can take >15s on a constrained node, and the
  probe times out waiting for HTTP headers — pod never reaches Ready
  on slower hardware. TCP probe just confirms nginx is listening on
  :80, which is sufficient for ingress routing; deeper application
  health surfaces through real Seahub paths from external clients.
- **Liveness probe removed entirely.** Seafile's all-in-one bootstrap
  (MySQL schema population, Django migrations, ccnet init, nginx
  upstream warmup) is slow on first start. A liveness probe with a
  tight kill timer creates a restart-loop death spiral — kubelet
  kills the pod mid-bootstrap, the next pod re-runs bootstrap from
  the persistent volume's mid-state, never converges. Restarting an
  actually-deadlocked Seafile is the operator's call, not the
  kubelet's. Readiness probe `initial_delay_seconds` bumped to 5min
  so it doesn't ding the pod while bootstrap is still populating.

### Added
- **`var.redis_password` — sensitive Redis auth credential.** The
  shared platform Redis is password-protected; Seafile 13 doesn't
  get its own scoped ACL user at engine-level (no per-app provisioner
  Job for Seafile), so it uses the default user with full access.
  Caller wires from `module.redis.default_password`. Empty default
  preserves zero-config behaviour for cluster Redis with auth
  disabled.

### Changed
- IngressRoute renamed from `seafile` to `seafile-fileserver` and
  scoped to the `/seafhttp` path only. The catch-all `Host(...)` →
  Seahub :80 route is no longer engine-emitted — it lands via the
  standard operator-side `kind: external` component yaml +
  domain-yaml route entry (same pattern Roundcube/mail uses), so
  the hostname mapping lives in one place (the domain yaml) and
  doesn't compete with an engine-side catch-all on the same host.

### Added
- Initial release. Single-pod Deployment of upstream
  `seafileltd/seafile-mc:13.x` (Seahub + ccnet + fileserver bundled).
  Backed by the platform's shared MySQL (Seafile 13 CE is MySQL-only)
  and Redis (default cache backend since 13). Longhorn-backed PVC
  mounted at `/shared` for libraries, blobs, history, ccnet state.
- One-shot setup Job creates the three Seafile databases (`ccnet_db`,
  `seafile_db`, `seahub_db`) plus a scoped `seafile` MySQL user via
  the shared instance's root credential — root password stays out of
  the running pod's bootstrap Secret.
- OIDC integration via `seahub_settings.py` ConfigMap rendered from
  Zitadel client (caller wires `oidc_client_id` /
  `oidc_client_secret` from a `module "<x>_oidc"` callsite).
  Auto-provisions Seafile users on first SSO login.
- Traefik IngressRoute splits `/seafhttp/*` (fileserver, after
  `StripPrefix`) from everything-else (Seahub UI). Bundled Caddy is
  bypassed — Traefik does TLS termination at the cluster boundary.
- Recreate strategy on the Deployment so two pods never share the
  PVC (Seafile holds open file handles on `/shared/seafile-data`).
