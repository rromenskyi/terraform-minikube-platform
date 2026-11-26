# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `extra_hosts`: gated hostnames on another domain than `cookie_domain`. Each gets `https://<host>/_oauth` as a redirect URI on the Zitadel application; traefik-forward-auth already sends their callback there and scopes the cookie to that host. The gated route must cover the whole host.

### Fixed
- The Zitadel application puts the userinfo claims (e-mail) into the ID token
  (`id_token_userinfo_assertion = true`). traefik-forward-auth reads the e-mail
  from the ID token only, so with `allowed_emails`/`allowed_domains` set every
  login was rejected as "Not authorized" (`Invalid email email=`).

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
