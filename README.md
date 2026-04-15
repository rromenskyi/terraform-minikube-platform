# terraform-minikube-platform

**A Terraform-first Kubernetes hosting platform powered by the external `terraform-minikube-k8s` module, Traefik, and Cloudflare Tunnel.**

This repository contains a clean, configurable platform for hosting multiple projects with custom domains, components, namespaces, resource limits, and zero-trust tunneling.

## Architecture

- **One domain = one YAML file** (`config/domains/*.yaml`)
- **Components** are reusable building blocks (`config/components/`)
- **Platform** is provisioned by the external `terraform-minikube-k8s` module
- **Projects** define namespaces, resource limits, and which reusable components to deploy
- Terraform is the entrypoint for cluster bootstrap; do not start Minikube manually as the normal workflow
- Everything is managed as code. Adding a new project is as simple as creating a new YAML file.

See `docs/architecture.md` for details.

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

Terraform bootstraps the Minikube cluster itself through the module. Manual `minikube start` is not part of the normal path.

5. Access dashboards:
   - Traefik: `traefik.yourdomain.com`
   - Grafana: `grafana.yourdomain.com`

Cloudflare Tunnel automatically handles public access with valid TLS certificates.

## Configuration

### Platform Module (`terraform-minikube-k8s`)
The shared platform layer comes from the external `terraform-minikube-k8s` module repository. For local development in this workspace, `main.tf` points to the sibling checkout at `../terraform-minikube-k8s`.

### Backend (`_backend.tf`)
Remote Terraform state is configured in the root stack via `_backend.tf`. The reusable `terraform-minikube-k8s` module intentionally stays backend-free.

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
