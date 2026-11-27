# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial module: node-problem-detector v1.37.0 (chart 2.4.2) with a
  kernel monitor that turns hung-task lines into the node condition
  `KernelDeadlock`; node-readiness-controller 0.6.0 with a
  NodeReadinessRule that taints such a node
  `readiness.k8s.io/KernelDeadlock:NoSchedule` while the condition holds
  (`dry_run`, default true, only reports); alerts `NodeKernelDeadlock`,
  `NodeKernelDeadlockSeveralNodes`, `NodeProblemDetectorUnavailable`.
