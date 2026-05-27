# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
