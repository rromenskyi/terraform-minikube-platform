# Platform and SRE rules (additional)

> **Canonical sync.** This file is mirrored byte-for-byte across `terraform-minikube-k8s`, `terraform-k3s-k8s`, `terraform-k8s-addons`, and `terraform-minikube-platform`. Changes must land in every repo in the same PR — the CI sync check (todo) will fail otherwise.

Companion rules to `AGENT.md` specific to Kubernetes platform operations.

## Core principles

- Observability first. A workload without metrics, logs, and readiness signals is not production.
- Configuration as data. YAML / DB rows grow; the Terraform code stays stable.
- Declarative and fully reproducible. Every persistent change is represented in the repo or in a Secret referenced by the repo.

## Kubernetes hardening checklist

- Pod Security Standards applied at the namespace level (`baseline` or `restricted`).
- NetworkPolicy where network-level isolation is a real requirement. Where it is not applied, state that explicitly in the consumer's docs instead of implying tighter isolation than the cluster enforces.
- Resource `requests` and `limits` are mandatory on every container. Setup jobs and sidecars included.
- No privileged containers unless the workload provably requires it (node-exporter, some CNI daemons). Document why.
- `readOnlyRootFilesystem: true` wherever the workload tolerates it.
- `startupProbe`, `readinessProbe`, `livenessProbe` tuned to the workload, not copy-pasted.

## Ingress, TLS, and routing

- Traefik ingress configuration belongs with the module that owns the hostname. Cross-namespace IngressRoute references are allowed only where the trust model documents it.
- cert-manager ClusterIssuers target specific entrypoints (`websecure`, Gateway API). Do not create issuers whose HTTP-01 solver has no ingress class to use.
- TLS termination position (edge vs Traefik vs pod) is a deliberate choice. Document it in the repo's README; do not leave operators guessing which hop holds the cert.

## Monitoring and alerting

- kube-prometheus-stack as the reference stack. Prefer `ServiceMonitor` / `PodMonitor` CRDs over annotations.
- Grafana dashboards are version-controlled (JSON in the repo, or provisioned via ConfigMap). No dashboards stored only in the running instance.
- Alert rules state the condition, the impact, and the runbook link. "High CPU" without impact is noise.

## Operational sanity

- Every workload must survive `terraform destroy && terraform apply` on a new cluster. If it does not, the reason (persistent state, external DNS, manual step) is explicit in the README.
- `./tf bootstrap-*` or equivalent wrapper scripts do not silently wipe persistent host volumes. Destructive steps require an explicit operator confirmation.
- "Works on my machine" is not a fix state. Reproduce on a clean environment before closing an issue.
