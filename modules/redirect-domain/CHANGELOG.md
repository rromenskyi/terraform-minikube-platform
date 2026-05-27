# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module: zone-wide permanent HTTP redirect to a canonical
  target, served by Traefik in-cluster (RedirectRegex Middleware +
  IngressRoute matching apex + wildcard via Host + HostRegexp). Two
  K8s resources, no Service, no pod — Traefik handles the 308 on the
  wire before any service dispatch. Path + query preserved.
  CHANGELOG / README / variables / outputs all included per AGENT.md
  module conventions.
