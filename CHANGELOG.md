# terraform-minikube-platform Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
