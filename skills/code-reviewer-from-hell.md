# Code review checklist

> **Canonical sync.** This file is mirrored byte-for-byte across `terraform-minikube-k8s`, `terraform-k3s-k8s`, `terraform-k8s-addons`, and `terraform-minikube-platform`. Changes must land in every repo in the same PR — the CI sync check (todo) will fail otherwise.

Use this checklist when reviewing a pull request or auditing a change before commit. The goal is a signed-off state that would survive a third-party security / reliability review without rework.

## Blockers (request changes until fixed)

- Variables without `description`, without `type`, or without a `validation` block on enum-shaped / bounded-range inputs.
- Hardcoded values (hostnames, CIDRs, image tags, ports) that belong in a variable or `local`.
- `count` used as a toggle where `for_each = toset(["enabled"]) : toset([])` is the idiom.
- `count = 0` left behind as a disable hack; remove the resource or move it behind an `enable_*` flag.
- Outputs that depend on a conditional resource but do not collapse to `null` via `one([for ... ])`.
- Outputs that propagate a password / token / certificate without `sensitive = true`.
- Missing `depends_on` where the graph cannot infer the real ordering.
- `lifecycle { ignore_changes = all }` — isolate the one drifting field instead.
- Commented-out code. Delete it; git history is the archive.
- README / CHANGELOG out of sync with the code change in the same PR.
- Breaking input/output change without a `**BREAKING**` CHANGELOG entry that tells a consumer how to migrate.

## Should-fix (address before merge unless a follow-up issue is filed)

- Files not separated by responsibility — a `main.tf` that does wiring, resource creation, and output derivation.
- Repeated expressions that should live in a `locals` block.
- Comments that describe what the code does rather than why it does it this way.
- Stale comments referencing moved or removed behaviour.
- Non-idiomatic Terraform — deeply nested `dynamic` blocks, clever ternaries, misuse of `templatefile` for values that should be regular HCL.
- Resource names tied to implementation (`secret_1`, `cm_final`) instead of to intent.

## Review tone

- Name the issue precisely; point at the file and line; show the better alternative in-line.
- No "I would fire someone for this" energy, no personal remarks. Findings stand on their own.
- If a change is acceptable as-is but sub-optimal, say so and move on. Not every finding is a blocker.
