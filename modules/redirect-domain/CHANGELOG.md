# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- **Catch-all redirect no longer shadows explicit per-host routes on the
  same zone.** The IngressRoute now carries `priority: 1`, pinning it to
  the bottom of Traefik's route table. Traefik's default priority is the
  match-rule length, and the apex+wildcard OR'd rule is long enough to
  outrank a plain `Host(...)` rule emitted for a `routes:` entry — a
  carve-out subdomain on an otherwise redirect-only domain (e.g. a
  link-tracking host) was 308-redirected instead of reaching its
  service.

### Added
- Initial module: zone-wide permanent HTTP redirect to a canonical
  target, served by Traefik in-cluster (RedirectRegex Middleware +
  IngressRoute matching apex + wildcard via Host + HostRegexp). Two
  K8s resources, no Service, no pod — Traefik handles the 308 on the
  wire before any service dispatch. Path + query preserved.
  CHANGELOG / README / variables / outputs all included per AGENT.md
  module conventions.
