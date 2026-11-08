# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- Chart 0.16.2 (MetalLB v0.16.2): gRPC 1.84, fixing CVE-2026-33186 in the controller and speaker.
  Upgrade note: 0.16.2 changes how the memberlist encryption key is derived, so old and new speakers cannot exchange gossip while the speaker DaemonSet rolls. In L2 mode a VIP with several candidate nodes may be announced by more than one speaker until the rollout completes; pools pinned to a single node (L2Advertisement `nodeSelectors`, or `externalTrafficPolicy: Local` with endpoints on one node) are not affected.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
