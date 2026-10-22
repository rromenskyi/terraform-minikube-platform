# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `vault_auth_role`: authenticate the password sync through an own VaultAuth with a narrow role instead of VSO's default.
- Initial module: Samba file server on a StorageClass volume, MetalLB L2
  address (`externalTrafficPolicy: Local`, no NodePorts), passwords from
  Vault via VSO, rsync seed from an existing hostPath tree, fast failover
  tolerations.
