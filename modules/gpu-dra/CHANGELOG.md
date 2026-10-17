# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- dra-driver-dri 0.1.1. ClusterRole without claim-status rules (the plugin
  never writes claim status); a ValidatingAdmissionPolicy limits
  ResourceSlice writes to the plugin pod's own node.
- DRIVRAMOverUse compares used VRAM with allocated + reserve.

### Added
- Module: DRA driver for DRM render-node GPUs (`ipsupport-llc/dra-driver-dri`
  0.1.0) with DeviceClass, PodMonitor and alerts.
