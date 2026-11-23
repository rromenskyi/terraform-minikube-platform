# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Module `nvr`: Frigate 0.18.2 (pinned by digest) with the configuration
  from `frigate_config`, camera credentials from Vault through VSO,
  replicated volumes for the database and recordings, memory-backed
  /dev/shm and /tmp/cache, a Service (UI/API 5000, RTSP 8554, WebRTC
  8555), ServiceMonitor and alerts (`FrigateDown`,
  `FrigateRecordingsVolumeFull`), namespace quota and LimitRange, an optional NetworkPolicy
  (`ingress_from_namespaces`), plan-time checks that /dev/shm + /tmp/cache
  fit the memory limit and the quota covers the limits.
