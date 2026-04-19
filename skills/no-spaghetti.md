# No-Spaghetti, No-Hacks Skill (always active)

> **Canonical sync.** This file is mirrored byte-for-byte across `terraform-minikube-k8s`, `terraform-k3s-k8s`, `terraform-k8s-addons`, and `terraform-minikube-platform`. Changes must land in **every** repo in the same PR — the CI job (todo) will fail otherwise.


You do not ship spaghetti, crutches, or clever one-off patches. Every
line is either obviously correct or has an inline comment explaining a
*non-obvious constraint* (not a "what", a "why"). Apply this mode when
reading, writing, or reviewing anything in this repo.

### Hard rules (no exceptions)

**Terraform discipline**
- `for_each` over `count`. `count = 0` is not a toggle — use an `enabled` bool wired through `for_each = toset(["enabled"]) : toset([])`.
- `one([for x in resource : ...])` to collapse disabled resources to `null`. Consumers then get a clean nullable contract.
- `dynamic {}` blocks only when the spec genuinely varies by instance. Never used to hide a conditional that should be two explicit resources.
- `depends_on` exists for ordering the graph cannot infer — not to paper over a race. If you reach for it to "fix" a timing bug, first ask *why* the reference isn't there.
- `lifecycle { ignore_changes = [everything] }` is a code smell. Isolate the one field that legitimately drifts; leave the rest managed.
- Provider constraints (`~> X.Y`) in one `_versions.tf`, never scattered into individual `.tf` files.

**Structural hygiene**
- One `.tf` file per concern. `main.tf` is wiring + locals only, never a dump bin.
- `locals` compute *once*, are named for intent, and feed downstream. No three copies of the same expression inlined.
- Resource names match the concept, not the implementation detail (`kubernetes_secret_v1.db_credentials`, not `secret_1`).
- No magic strings: every hostname, port, path goes through a variable or local, not a bare literal buried in a nested block.
- YAML schemas and their TF loaders are **tight**: a key is either required, optional with a default, or not allowed — no silent tolerance.

**Bug fixes**
- Find the root cause, don't sedate a symptom. A `sleep 10` is not a fix; a missing `depends_on` might be. A `try(..., null)` is not a fix; a missing required variable might be.
- Never disable pre-commit hooks, validations, or CI guards to get a change in. If the guard is wrong, fix the guard. If it's right, fix the code.
- Never paper over a failing apply with `taint` + re-apply loops. Understand why state diverged.

**Comments**
- Comments explain **why**, never **what**. If the code is so dense that a "what" comment is needed, the code is wrong.
- Stale comments are lies. When you change a block, re-read every comment near it and update or delete.
- No commented-out code. If you are scared to delete, your git history is the archive.

**Config and secrets**
- Secrets go through `random_password` + Kubernetes `Secret` / external vault. Never into `.tf`, never into YAML, never into CHANGELOG.
- `.example` files are a tracked source of truth for the schema; the live file is gitignored. Drift between `.example` and the loader is a blocker.

**Breaking changes**
- Breaking input/output surface goes into CHANGELOG `### Changed` with **BREAKING** prefix and a one-line migration note. A downstream operator must be able to migrate from the commit message alone.

### Review stance

When you see spaghetti or a hack, do not patch around it. Name it, extract
the root cause, refactor, or reject the PR. No "let's land this and fix
later" — "later" is where spaghetti compounds.

You are in this mode at all times.
