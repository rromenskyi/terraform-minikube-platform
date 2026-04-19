# AGENT.md — Repository Engineering Standards

> **Canonical sync.** This file is mirrored byte-for-byte across `terraform-minikube-k8s`, `terraform-k3s-k8s`, `terraform-k8s-addons`, and `terraform-minikube-platform`. Changes must land in every repo in the same PR; the CI sync check (todo) will fail otherwise. Repository-specific rules, when they exist, live in each repo's README under an "Engineering standards" section.

The contents of this file apply to every change made in this repository. The rule sets under `skills/` stack on top and are read together with this file.

## Coding philosophy

1. Explicit over implicit. No environment-driven magic; no hidden global state.
2. Fail fast, fail loud. Surface wrong configuration at plan time, not in production.
3. Everything is code. No click-ops; no out-of-band kubectl edits that are not reflected in the repo.
4. If it is not in the repo, it does not exist.
5. Terraform should be boring. Avoid clever `dynamic` blocks, deep ternaries, or abstraction layers a reader cannot follow.
6. Modularity, reusability, and clear separation of concerns. One `.tf` file per concern; `main.tf` is wiring and `locals` only.
7. Every resource has sensible defaults and sensible overrides via variables.

## Terraform rules

- Follow terraform-docs, Semantic Versioning, and maintain `CHANGELOG.md` with an `## [Unreleased]` section at the top.
- Every module ships `variables.tf`, `outputs.tf`, `README.md`, `CHANGELOG.md`, all with descriptions that explain intent and constraints, not just types.
- Prefer `for_each` over `count`. `count = 0` is not a toggle — use `for_each = var.enabled ? toset(["enabled"]) : toset([])` wired from an `enable_*` bool.
- Use `one([for x in resource : ...])` to collapse disabled resources to `null`; downstream consumers see a clean nullable output.
- Use data sources instead of hardcoding values whenever possible.
- Never commit sensitive data — use `random_password`, Kubernetes Secrets, or external vaults. Mark outputs that propagate secrets `sensitive = true`.
- Remote state backend configuration lives in consumer root stacks, not in reusable child modules.
- `lifecycle { ignore_changes, prevent_destroy }` and explicit `depends_on` each have a cost. Reach for them only when the resource graph cannot express the real relationship; add a comment explaining why.
- Validate inputs at the source. Enum-shaped variables use `validation { condition = contains([...], var.x) }`; CIDRs, DNS labels, emails go through regex validation with actionable `error_message`s.

## Kubernetes and platform rules

- Default security posture: Pod Security Standards (`baseline` or `restricted`), default `ResourceQuota` and `LimitRange` on every module-managed namespace, hardened workloads (`runAsNonRoot`, drop ALL Linux capabilities, `readOnlyRootFilesystem` where possible).
- Where routing is the module's job, own it cleanly. Where it belongs to the consumer, keep the chart-side public route disabled and expose Service coordinates — not a URL — as the module output.
- Observability-first: Prometheus + Grafana with proper ServiceMonitors, dashboards as code, meaningful alerting rules.

## Code quality

- Code should be maintainable by a junior engineer two years from now without help.
- Every variable, output, and resource block has a description. Resource names match the concept, not the implementation detail.
- Use `locals` for complex logic and centralised naming. Compute once, reuse.
- Comments explain why, not what. If a "what" comment feels necessary, the code is wrong.
- All repository-facing content — code, comments, documentation, commit messages, CHANGELOG entries, YAML keys — in English only.

## Workflow

1. Understand the business/platform goal before proposing an implementation.
2. Propose the simplest correct solution; call out cleaner, more secure, or more observable alternatives when you see them.
3. Breaking changes to inputs or outputs go into `CHANGELOG.md` under `### Changed` with a **BREAKING** prefix and an inline migration note a downstream operator can follow from the commit message alone.
