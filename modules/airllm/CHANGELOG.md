# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module, extracted from the root `airllm.tf`: one AirLLM instance
  (Argo CD Application from the public chart, database and Redis ACL user
  on the shared services, runtime Secret, DNS record, certificate and
  routes). New over the root version: `seed_from_database` (one-time copy
  into an empty database) with `master_key`, `redis_db`, OIDC login
  (`oidc`, `oidc_client_secret`), `replicas`, `app_env`, and switches for
  the chart's dashboards and alert rule.
