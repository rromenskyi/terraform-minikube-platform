# terraform-minikube-platform Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `var.host_volume_path` is now used verbatim as the hostPath prefix by every downstream module — no regex translation, no auxiliary `local.minikube_volume_path`. The value has to match what the kubelet sees on the node, which differs by distribution (native k3s / macOS Docker-driver minikube / Linux Docker-driver minikube); the README and `docs/architecture.md` cover the three cases
- Default for `var.host_volume_path` is `/data/vol` (Linux-native scenario). macOS Docker-driver minikube operators now set `host_volume_path=/minikube-host/Shared/vol` explicitly via `.env`
- `.env.example` documents `HOST_VOLUME_PATH` with per-distribution guidance
- `terraform-k3s-k8s` module source bumped to `v0.2.2` (v0.2.1 fixed a node-registration race in the k3s installer remote-exec; v0.2.2 moves `commonLabels` under `global` for the cert-manager chart and aligns the traefik namespace to `ingress-controller`)
- `terraform-minikube-k8s` reference in the commented Option A block bumped to `v2.1.1` (same cert-manager `global.commonLabels` fix as the k3s sibling)
- `./tf` wrapper reshaped into composable subcommands: `cloudflare-purge` is now a standalone verb, `bootstrap` was split by distribution into `bootstrap-minikube` (Option A, phased) and `bootstrap-k3s` (Option B, single-phase). A bare `./tf bootstrap` prints the two options and exits non-zero
- `./tf` wrapper no longer double-prefixes keys that already start with `TF_VAR_` (was a silent bug — pre-fixed keys like `TF_VAR_ssh_host` became `TF_VAR_tf_var_ssh_host` and never reached Terraform)

### Fixed
- Cloudflare DNS cleanup in `./tf` is now scoped by the target tunnel's UUID (`endswith(<tunnel_id>.cfargotunnel.com)`) instead of the previous blanket `endswith(cfargotunnel.com)` filter. The old filter would delete CNAMEs for every tunnel on the account — including unrelated ones such as an operator's SSH-over-tunnel proxy — whenever bootstrap ran

### Removed
- `local.minikube_volume_path` and the `replace(..., "Users", "minikube-host")` heuristic

## [0.1.0] - 2026-04-18

Initial public release.

### Added
- Terraform root stack for a multi-tenant local Kubernetes hosting platform fronted by Cloudflare Zero Trust Tunnel
- Swappable cluster distribution: `module "k8s"` sources from GitHub-pinned releases
  - `terraform-minikube-k8s` `v2.1.0` — Option A (default, docker driver, Flannel, NodePort Traefik)
  - `terraform-k3s-k8s` `v0.2.0` — Option B (native k3s over SSH, `install_k3s=false` for adoption mode)
- Signature-compatible cluster modules: provider wiring is distribution-agnostic, switching the active block requires no changes to downstream code
- Root `kubernetes` / `helm` / `kubectl` providers consume `module.k8s.kubeconfig_path` via `config_path`, enabling single-phase `terraform apply` against a cold state
- Shared MySQL 8.0 StatefulSet with auto-provisioned per-tenant databases and users (`modules/mysql/`)
- Per-tenant `modules/project/` creates namespace, `ResourceQuota`, `LimitRange`, component Deployments + Services, Traefik IngressRoutes with Let's Encrypt certs, and MySQL credentials secret
- Reusable `modules/component/` (Deployment + Service + PV/PVC + ConfigMap) driven by `config/components/*.yaml`
- Tenant YAMLs under `config/domains/*.yaml` (gitignored; `.example` templates tracked)
- Cloudflare Zero Trust tunnel with hostnames dynamically aggregated from project modules, including infra services (`traefik.<infra-domain>`, `grafana.<infra-domain>`) — gracefully collapses to a catch-all rule when no tenant is configured yet
- Dedicated `cloudflared` Deployment in the `ops` namespace
- Host-volume path support for the Mac Docker-driver Minikube (`/Users/Shared/vol` mounted as `/minikube-host/Shared/vol`)
- `./tf` bootstrap wrapper with `bootstrap`, `plan`, `apply`, `destroy` subcommands
- MIT LICENSE
- Pre-commit hooks: `terraform_fmt`, `terraform_validate`, `terraform_trivy` (HIGH/CRITICAL gate), `gitleaks`, `detect-private-key`, `check-merge-conflict`
- Repository-level backend (`_backend.tf`, Backblaze B2 S3-compatible) and provider constraints (`_versions.tf`)

### Security
- `.gitignore` blocks real tenant YAMLs, `.env` files, `*.tfvars`, kubeconfigs, and local state
- `.env.example` ships only placeholders; operator credentials never enter the tree
- Git history was purged of operator-identifying strings via `git filter-repo --replace-text`
