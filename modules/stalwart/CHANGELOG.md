# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
- Pod spec now sets `service_account_name = "default"` explicitly on the
  Deployment. The kubernetes Terraform provider doesn't reliably clear a
  previously-set string field by omission, so leaving the field implicit
  leaves the live Deployment pinned to whatever SA was last assigned. With
  the explicit value, a future Pod-side SA change (or removal) actually
  propagates through `terraform apply`. Defensive only — current Deployment
  was already pointing at `default`; this just makes the intent
  declarative.
