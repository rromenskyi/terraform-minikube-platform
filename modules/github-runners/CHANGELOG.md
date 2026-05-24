# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- **Vault-mode (`vault: true`) now documented as accepting GitHub-App credentials
  alongside PAT.** No code change — the ARC chart auto-detects PAT vs App by
  which keys are present in the Secret, so VSO syncs whatever the operator put
  in Vault. Operator places EITHER `github_token` (PAT mode, legacy) OR the
  App triple `github_app_id` + `github_app_installation_id` +
  `github_app_private_key` (App mode, preferred for new entries — no listener-
  config staleness on rotation, scoped permissions, no SAML-bound user
  account). Existing PAT-shape entries unaffected. Docstring on `var.scale_sets`
  and the vault-mode block comment in `main.tf` updated.

### Added
- **Vault-mode for GitHub PAT delivery — `vault: true` on a `scale_sets` entry.**
  Third auth path alongside the existing operator-tokens-mode (`var.tokens`
  map fed from `.env`) and externally-managed-mode (`github_secret_name`
  pointing at a pre-created Secret carrying GitHub App fields). When
  `vault: true`, engine emits a `VaultStaticSecret` CR in the scale set's
  namespace pointing at the convention path
  `secret/data/platform/github-runner-tokens/<scale-set-key>`; operator
  places the PAT under one data key `github_token` via Vault UI / CLI,
  VSO syncs into `<scale-set-key>-github-pat` Secret. Chart consumes the
  same Secret name as in operator-tokens-mode — only source-of-truth
  differs. Engine also emits the `vault-secrets-operator-controller-manager`
  ServiceAccount in every scale-set namespace that contains at least one
  vault-mode entry (VSO impersonates the SA in the consuming namespace
  during k8s-auth login). Modes are mutually exclusive; precondition
  catches double-wired entries at plan time. Preferred path for new
  scale sets — eliminates `.env` PAT exposure and lets operators rotate
  via Vault UI without TF re-apply.
- `kubectl` provider declared in `required_providers` (used by the new
  `kubectl_manifest.github_pat_vault` resource).

### Changed
- `var.tokens` description marked LEGACY — kept in place for the migration
  window while existing scale sets move from operator-tokens-mode to
  vault-mode one at a time.
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
