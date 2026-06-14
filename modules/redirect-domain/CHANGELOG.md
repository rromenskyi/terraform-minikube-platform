# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`priority` and `include_subdomains` inputs — single-host redirects.**
  `include_subdomains` (default true) keeps the whole-zone behaviour
  (apex + `*.from_domain`); set false to match only the exact
  `from_domain`, for redirecting one host that sits on an otherwise
  redirect-only zone. `priority` (default 2, unchanged for zone
  redirects) lets a single-host redirect pass a higher value so it wins
  over an overlapping zone redirect — Traefik's default rule-length
  priority proved unreliable when a long zone-redirect rule competes
  with a default-priority host route (observed live: a carve-out lost
  to the zone redirect despite a longer rule). Backward compatible:
  existing callers get the previous apex+wildcard, priority-2 shape.

### Fixed
- **Catch-all redirect no longer shadows explicit per-host routes on the
  same zone.** The IngressRoute now carries `priority: 2`, pinning it to
  the bottom of Traefik's route table. Traefik's default priority is the
  match-rule length, and the apex+wildcard OR'd rule is long enough to
  outrank a plain `Host(...)` rule emitted for a `routes:` entry — a
  carve-out subdomain on an otherwise redirect-only domain (e.g. a
  link-tracking host) was 308-redirected instead of reaching its
  service. Priority is 2, not 1: the platform-wide `traefik-fallback`
  router sits at 1, and an equal-priority tie is broken arbitrarily —
  at 1 the fallback "Service is starting up" page swallowed entire
  redirected zones.

### Added
- Initial module: zone-wide permanent HTTP redirect to a canonical
  target, served by Traefik in-cluster (RedirectRegex Middleware +
  IngressRoute matching apex + wildcard via Host + HostRegexp). Two
  K8s resources, no Service, no pod — Traefik handles the 308 on the
  wire before any service dispatch. Path + query preserved.
  CHANGELOG / README / variables / outputs all included per AGENT.md
  module conventions.
