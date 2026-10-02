# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- OIDC client secret moved from `argocd-cm` (ConfigMap) to `argocd-secret`;
  the config references `$oidc.clientSecret`.

### Changed
- `default` AppProject is emptied (it allowed everything to any Application
  naming it); platform-owned apps use the new `platform` project
  (`platform_apps`). The configured namespace is now passed in.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
