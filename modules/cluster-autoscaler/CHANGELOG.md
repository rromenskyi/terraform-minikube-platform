# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- cluster-autoscaler v1.37.0. Its externalgrpc provider reads the
  ResourceSlices in plugpool's node group templates, so a pending pod whose
  DRA claim (a GPU) fits the devices in a template can now trigger a scale-up
  of that group. The module's flags and RBAC are unchanged; the RBAC matches
  the upstream 1.37 core's own e2e role for `resource.k8s.io`.
- Poweroff pod image busybox 1.38.0.
- plugpool 0.2.0: node group templates carry the DRA devices
  (ResourceSlices) the machines published while powered on, kept in the
  ConfigMap `plugpool-template-slices`, so a cluster-autoscaler that reads
  them (1.37+) can power a machine on for a pending pod that claims a
  device. cluster-autoscaler 1.36 ignores them.

### Added
- Initial module: cluster-autoscaler v1.36.1 (externalgrpc) with the
  plugpool 0.1.0 sidecar, RBAC, config from `node_groups`, the plugs'
  password from Vault through VSO, Service + ServiceMonitor for metrics.
