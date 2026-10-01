# security-scan

Continuous CVE scanning of platform-system container images with
[`trivy-operator`](https://github.com/aquasecurity/trivy-operator)
(Aqua Security), reported through the platform's monitoring stack.

## Shape

- **Scanner.** trivy-operator watches Pods in the platform-system
  namespaces (allowlist in `main.tf::local.target_namespaces`, extendable
  with `extra_target_namespaces`), scans each unique image and writes a
  `VulnerabilityReport` next to the workload. Reports expire after the
  chart's TTL (24h) and are rescanned, so they describe what runs now.
  Tenant namespaces are out of scope.
- **Metrics.** With `service_monitor_enabled`, Prometheus scrapes the
  operator's `trivy_image_vulnerabilities` gauge (labels: image, severity,
  workload namespace).
- **Alerts.** With `alerts_enabled`, a PrometheusRule raises
  `ImageVulnerabilities` per image with fixable findings at
  `alert_severities`, and `SecurityScanNoData` when the scanner exports
  nothing for 6h — so silence can't also mean "broken". Alerts carry
  `namespace=<this namespace>` plus `alert_labels`, so one Alertmanager
  route delivers them.

Scans run as clients of the chart's built-in trivy server, which keeps
the vulnerability DB on a PVC (`builtin_trivy_server`).

Defaults keep the footprint small: only the vulnerability scanner runs
(config audit, RBAC, infra, secret and SBOM reports are off), at most
`scan_jobs_concurrent_limit` scans run at once, unfixed findings are
ignored, and the operator gets no cluster-wide Secret access (private
images then show up as scan failures).

## Looking at findings

```sh
kubectl get vulnerabilityreports -A \
  -o custom-columns=NS:.metadata.namespace,IMAGE:.report.artifact.repository,TAG:.report.artifact.tag,CRIT:.report.summary.criticalCount,HIGH:.report.summary.highCount
```

In Prometheus/Grafana: `sum by (image_repository, image_tag, severity) (trivy_image_vulnerabilities)`.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
