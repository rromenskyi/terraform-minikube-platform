# Terraform rules (additional)

> **Canonical sync.** This file is mirrored byte-for-byte across `terraform-minikube-k8s`, `terraform-k3s-k8s`, `terraform-k8s-addons`, and `terraform-minikube-platform`. Changes must land in every repo in the same PR — the CI sync check (todo) will fail otherwise.

Companion rules to `AGENT.md` specific to Terraform hygiene.

## Project structure

- Every `.tf` file has a single clear responsibility.
- `main.tf` contains only module wiring and `locals`.
- Always include `variables.tf`, `outputs.tf`, `_providers.tf`, `_versions.tf`.
- Separate concerns by domain: networking, security, compute, observability, applications.

## Production practices

- Resources that support metadata carry meaningful `tags` / `labels` / `annotations` identifying the owning module and the managed-by marker.
- Use `prevent_destroy = true` only for resources that cannot be recreated cheaply (databases, persistent buckets, long-lived volumes). Add a comment explaining the guard; never apply it by reflex.
- `depends_on` is a tool for cross-provider ordering the graph cannot infer. Do not use it to paper over a missing reference or a race.
- Prefer `for_each` over `count`. Collapse disabled resources with `one([for x in resource : ...])` so downstream outputs are clean nullable values.
- Outputs that propagate secrets are `sensitive = true`.
- Use data sources instead of hardcoded values when a real source exists.

## Naming and readability

- Variable names describe intent, not implementation detail.
- Every variable has a description that explains constraints, not just the type. Enum-shaped variables have a `validation` block listing the valid values and an `error_message` that tells the operator what to do.
- Use `locals` for complex expressions, derived names, or values reused in more than one place.
- All repository-facing content is English.

## State and security

- Remote state is mandatory in consumer root stacks. Reusable modules do not declare a `backend` block.
- Backend access follows least privilege.
- Understand `terraform state mv`, `import`, `taint`, and partial state. Use them instead of destroying and recreating state when state has drifted from reality.
- Never store sensitive values in state when avoidable; mark what you cannot avoid `sensitive = true`.

## Module contract

- Every module ships `variables.tf`, `outputs.tf`, a `README.md`, and a `CHANGELOG.md` with an `## [Unreleased]` section at the top.
- Breaking input/output changes go into `### Changed` with a `**BREAKING**` prefix and a one-line migration note a downstream operator can follow from the commit message alone.
- Outputs that reference resources created under an `enable_*` flag collapse to `null` via `one([for ... ])` when the flag is off.
