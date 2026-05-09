# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial extraction from the root `buildkitd.tf` file. Resources, defaults,
  inputs, and outputs are functionally identical to the prior root-inline
  shape; only the address layout changed (every resource now lives under
  `module.buildkitd.*`). Operator runs `terraform state mv` to relocate the
  three live resources before the next apply.
