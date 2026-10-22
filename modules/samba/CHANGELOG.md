# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- Clearing `seed` deadlocked the apply: Terraform deleted the seed claim (held by the running pod) before updating the Deployment that drops it. The seed PV/PVC are create-before-destroy now, so the Deployment goes first (effective from the apply after the one that records it).

### Added
- `vault_auth_role`: authenticate the password sync through an own VaultAuth with a narrow role instead of VSO's default.
- Initial module: Samba file server on a StorageClass volume, MetalLB L2
  address (`externalTrafficPolicy: Local`, no NodePorts), passwords from
  Vault via VSO, rsync seed from an existing hostPath tree, fast failover
  tolerations.
