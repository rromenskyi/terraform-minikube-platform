# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Per-pod VRAM attribution: the DaemonSet runs with `hostPID` and
  `SYS_PTRACE` so the driver reads every GPU process's DRM fdinfo and exports
  `dri_claim_vram_used_bytes` / `dri_claim_vram_bytes` (labels device,
  namespace, pod). Alert `DRIClaimVRAMOverClaim` names a pod that uses more
  than it claimed (DRA accounts, the kernel does not cap). Needs a
  dra-driver-dri image with per-pod attribution.

### Changed
- dra-driver-dri 0.1.2 (GTT, temperature and clock metrics). ClusterRole without claim-status rules (the plugin
  never writes claim status); a ValidatingAdmissionPolicy limits
  ResourceSlice writes to the plugin pod's own node.
- DRIVRAMOverUse compares used VRAM with allocated + reserve.

### Added
- `node` label on the scraped series, alert `DRIVRAMEvictedToRAM`, Grafana
  dashboard "GPUs (dra-driver-dri)".

### Added
- Module: DRA driver for DRM render-node GPUs (`ipsupport-llc/dra-driver-dri`
  0.1.0) with DeviceClass, PodMonitor and alerts.
