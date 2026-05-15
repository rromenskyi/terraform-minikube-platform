# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
