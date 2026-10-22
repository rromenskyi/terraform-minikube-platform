# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- The seed refuses to run when its source holds no files: `rsync --delete` from an empty or missing old tree would wipe the volume.
- Clearing `seed` deadlocked the apply: Terraform deleted the seed claim (held by the running pod) before updating the Deployment that drops it. The Deployment now names the claim instead of referencing the resource, so both changes run at once. (A create-before-destroy fix tried first forced create-before-destroy onto everything the module depends on — `depends_on` reaches module.piraeus — and replacing a fixed-name StorageClass then failed with "already exists"; removed.)

### Added
- `vault_auth_role`: authenticate the password sync through an own VaultAuth with a narrow role instead of VSO's default.
- Initial module: Samba file server on a StorageClass volume, MetalLB L2
  address (`externalTrafficPolicy: Local`, no NodePorts), passwords from
  Vault via VSO, rsync seed from an existing hostPath tree, fast failover
  tolerations.
