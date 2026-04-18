# terraform-minikube-platform

**A Terraform-first Kubernetes hosting platform powered by an external cluster module (minikube or k3s), Traefik, and Cloudflare Tunnel.**

This repository contains a clean, configurable platform for hosting multiple projects with custom domains, components, namespaces, resource limits, and zero-trust tunneling.

## Architecture

- **One domain = one YAML file** (`config/domains/*.yaml`)
- **Components** are reusable building blocks (`config/components/`)
- **Platform** is provisioned by one of two sibling cluster modules:
  - [`terraform-minikube-k8s`](https://github.com/rromenskyi/terraform-minikube-k8s) — default
  - [`terraform-k3s-k8s`](https://github.com/rromenskyi/terraform-k3s-k8s) — alternative
- **Projects** define namespaces, resource limits, and which reusable components to deploy
- Terraform is the entrypoint for cluster bootstrap; do not start the cluster manually as the normal workflow
- Everything is managed as code. Adding a new project is as simple as creating a new YAML file.

The two cluster modules are drop-in replacements for each other — they export the same output signature (`cluster_host`, `client_certificate`, `client_key`, `cluster_ca_certificate`, `grafana_credentials`, …). Everything below the cluster block in `main.tf` (providers, Cloudflare tunnel, project modules) is distribution-agnostic.

See `docs/architecture.md` for details.

## Choosing the cluster distribution

Pick one in `main.tf`:

### Option A — minikube (default)

- **Requires:** `docker` + `minikube` CLI on `PATH`
- **Bootstrap:** single `terraform apply` — the minikube provider creates the cluster synchronously.
- **Active by default.** Nothing to change.

### Option B — k3s (native, via SSH)

- **Requires:** SSH daemon on the target host (`127.0.0.1` works for a local install) and an SSH user with **passwordless sudo**
- **Bootstrap:** single `terraform apply`. The root `kubernetes` and `helm` providers wire themselves through `config_path = module.platform.kubeconfig_path`, which is opened lazily at resource-apply time — by then `null_resource.k3s_install` has already written the kubeconfig.

To switch to k3s:

1. In `main.tf`, comment out the **Option A** block and uncomment the **Option B** block.
2. In `.env`, set `TF_VAR_ssh_user` and `TF_VAR_ssh_private_key_path` (see `.env.example`).
3. `terraform apply`.

Switching between distributions on a live state recreates the cluster — the underlying resources are different module sources.

## Quick Start

1. Copy environment file:
   ```bash
   cp .env.example .env
   # Edit .env with your B2 backend, Terraform, and Cloudflare values
   ```

2. Export the variables for Terraform and manifest rendering:
   ```bash
   set -a
   source .env
   set +a
   ```

3. (Optional) Customize projects in `config/domains/`

4. Deploy:
   ```bash
   terraform init
   terraform apply
   ```

Terraform bootstraps the cluster itself through the chosen module. Manual `minikube start` or `curl | sh` invocations are not part of the normal path.

5. Access dashboards:
   - Traefik: `traefik.yourdomain.com`
   - Grafana: `grafana.yourdomain.com`

Cloudflare Tunnel automatically handles public access with valid TLS certificates.

## Configuration

### Platform Module
The shared platform layer comes from one of the sibling cluster modules (see "Choosing the cluster distribution" above). `main.tf` expects the selected module checked out next to this repository at `../terraform-minikube-k8s` or `../terraform-k3s-k8s`.

### Backend (`_backend.tf`)
Remote Terraform state is configured in the root stack via `_backend.tf`. The reusable cluster modules intentionally stay backend-free.

### Projects (`config/domains/*.yaml`)
One file per domain. Example:

```yaml
name: example.com
namespace: "demo"
environment: "prod"

components:
  - web
  - echo

limits:
  cpu: "2"
  memory: "4Gi"
```

### Components (`config/components/*.yaml`)
Reusable defaults for application components, for example image, port, replicas, and optional overrides.

## Engineering Guidelines

This repository includes `AGENT.md` and the `skills/` directory.

These files provide structured engineering guidelines for AI coding assistants. When used with repository context, they reinforce consistent infrastructure standards, code review expectations, and English-only repository content.

To extend the guidelines, add new focused files to the `skills/` directory.

## Development

```bash
terraform fmt -recursive
terraform validate
terraform plan
```

Pull requests are welcome.

---

**Built as a real internal developer platform.**

License: MIT
