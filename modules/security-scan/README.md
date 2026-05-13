# security-scan

Continuous CVE scanning of platform-system container images, with a
weekly snapshot committed to the engine repo as an audit trail.

## Shape

Two layers, both Terraform-managed in this module.

**Bottom**: upstream [`trivy-operator`](https://github.com/aquasecurity/trivy-operator)
(Aqua Security) installed via Helm. Watches Pods cluster-wide,
dispatches a trivy scan per unique image, writes the result back as a
`VulnerabilityReport` CRD next to the workload it covers. Configured
to scan only the platform-system namespaces (allowlist in
`main.tf::local.target_namespaces`); tenant project namespaces are
intentionally excluded in v0. Severity floor `HIGH,CRITICAL`.

The trivy vulnerability DB (~700 MB) lives on a hostPath PV pinned to
a stateful tier node so operator pod restarts don't re-pull on every
scrape.

**Top**: a weekly `CronJob` (default Sunday 04:00 UTC) collects every
active VulnerabilityReport across the allowlist, formats the HIGH +
CRITICAL findings into a single markdown table, and commits that as
`inventory/cve-report.md` in the platform repo via a force-pushed
branch + GitHub API PR. If the report didn't change since last run
(modulo the `Generated:` timestamp line), the CronJob exits silently
— no PR, no noise. New CVEs or image bumps trigger PR open / refresh.

## Operator setup

1. Mint a classic GitHub PAT with scope `repo` (full) for
   `<owner>/terraform-minikube-platform`. Personal account that has
   write access to the repo. No expiration is fine; rotate via
   replace-in-Vault when needed (no TF re-apply required).
2. Place the PAT in Vault under
   `secret/data/platform/github-deploy-tokens/security-scan` with one
   data key `github_token`. VSO syncs into the
   `security-scan-github-pat` Secret in the module namespace within
   `refreshAfter: 30s`.
3. Set `services.security_scan.enabled: true` in `config/platform.yaml`.
4. `./tf apply`.

The first weekly run will commit the initial snapshot. Subsequent runs
update the same branch (`security-scan/snapshot` by default) — one
long-lived PR rather than a new branch each week.

## Scope evolution (v1)

Tenant project namespaces (matching `var.namespace_prefix` on the root
stack — default `phost-*`) are out of v0 scope to avoid leaking
operator-private image refs into the public engine repo via the
snapshot file. v1 will add a `targetNamespaces` extension that reads
`var.namespace_prefix` to template the tenant allowlist + handle the
public-vs-private split (likely opaque tenant labels in the public
report + private mapping kept out of the repo).

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
