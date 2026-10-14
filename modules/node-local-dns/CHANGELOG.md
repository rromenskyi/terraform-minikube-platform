# node-local-dns Changelog

All notable changes to this module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this module adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial module: NodeLocal DNSCache (`k8s-dns-node-cache` 1.27.1) as a
  DaemonSet on every node, bound to a link-local address and the cluster DNS
  Service address (no kubelet change), `kube-dns-upstream` Service, names
  outside the cluster domain through CoreDNS by default, `serve_stale`,
  optional `node_selector`, PodMonitor.
