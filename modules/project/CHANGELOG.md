# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`gcp_wif_service_accounts` — standalone WIF SA + credential-config for
  chart-managed workloads.** Per-env map of k8s SA name →
  `{ gcp_service_account }`. Engine emits a bare `ServiceAccount` plus a
  `<sa>-gcp-wif-credential-config` ConfigMap (same `external_account` shape
  as the per-component `gcp_wif` knob) without owning any Pod — for Argo CD
  helm charts that wire their own pod. Audience reuses
  `gcp_wif_pool_provider_audience`; a plan-time check fails if entries are
  declared while that audience is empty.
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
