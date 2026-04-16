# terraform-minikube-platform

**A Terraform-first Kubernetes hosting platform powered by an external cluster module (minikube or k3s), Traefik, and Cloudflare Tunnel.**

This repository provisions a complete local platform: Minikube cluster, ingress, TLS, observability, and zero-trust public access — all from a single `./tf bootstrap`.

## Architecture

- **One domain = one YAML file** (`config/domains/*.yaml`)
- **Components** are reusable building blocks (`config/components/*.yaml`)
- **Platform** is provisioned by one of two sibling cluster modules:
  - [`terraform-minikube-k8s`](https://github.com/rromenskyi/terraform-minikube-k8s) — default
  - [`terraform-k3s-k8s`](https://github.com/rromenskyi/terraform-k3s-k8s) — alternative
- **Projects** define namespaces, resource limits, and which reusable components to deploy
- **Cloudflare Tunnel** handles all public traffic — no LoadBalancer, no port-forwarding
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
- **Bootstrap:** single `terraform apply`. The root `kubernetes` and `helm` providers wire themselves through `config_path = module.k8s.kubeconfig_path`, which is opened lazily at resource-apply time — by then `null_resource.k3s_install` has already written the kubeconfig.

To switch to k3s:

1. In `main.tf`, comment out the **Option A** block and uncomment the **Option B** block.
2. In `.env`, set `TF_VAR_ssh_user` and `TF_VAR_ssh_private_key_path` (see `.env.example`).
3. `terraform apply`.

Switching between distributions on a live state recreates the cluster — the underlying resources are different module sources.

## Quick Start

1. Copy and fill the environment file:
   ```bash
   cp .env.example .env
   # Fill in Cloudflare API token, account/zone IDs, tunnel secret, and B2 backend values
   ```

2. Bootstrap the full platform (cluster + services + projects):
   ```bash
   ./tf bootstrap
   ```
   This resets the local minikube profile for the configured `cluster_name`, removes the local Terraform state file, purges the stale Cloudflare tunnel named `platform`, then runs cluster-first bootstrap followed by the full apply.

3. Access dashboards:
   - Grafana: `https://grafana.<your-domain>`
   - Traefik: `https://traefik.<your-domain>`

## Environment Variables (`.env`)

Terraform bootstraps the cluster itself through the chosen module. Manual `minikube start` or `curl | sh` invocations are not part of the normal path.

| Variable | Purpose |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token for provider (needs Tunnel:Edit, DNS:Edit, Zone:Read) |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID |
| `CLOUDFLARE_ZONE_ID` | Zone ID for your domain |
| `CLOUDFLARE_TUNNEL_SECRET` | Arbitrary secret used when creating the tunnel resource in Cloudflare API |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Backblaze B2 credentials for remote Terraform state |
| `B2_BUCKET` / `B2_ENDPOINT` | B2 bucket name and S3-compatible endpoint |
| `TF_VAR_ssh_user` / `TF_VAR_ssh_private_key_path` | Only required when using the k3s distribution |

> `CLOUDFLARE_TUNNEL_SECRET` is **not** the cloudflared JWT token. The JWT token that cloudflared uses to connect is derived automatically from the Cloudflare tunnel resource and injected into the Kubernetes secret by Terraform.

## Configuration

### Platform Module
The shared platform layer comes from one of the sibling cluster modules (see "Choosing the cluster distribution" above). `main.tf` expects the selected module checked out next to this repository at `../terraform-minikube-k8s` or `../terraform-k3s-k8s`.

### Backend (`_backend.tf`)
Remote Terraform state is configured in the root stack via `_backend.tf`. The reusable cluster modules intentionally stay backend-free.

### Projects (`config/domains/*.yaml`)

One file per domain. Example:

```yaml
name: example.com
namespace: example
environment: prod

components:
  - web
  - whoami
  - echo
```

### Components (`config/components/*.yaml`)

Reusable defaults per component — image, port, replicas:

```yaml
# config/components/echo.yaml
image: ealen/echo-server:latest
port: 80
replicas: 2
```

### Limits (`config/limits/default.yaml`)

Default namespace `ResourceQuota` applied to every project:

```yaml
cpu: "2"
memory: "4Gi"
```

> With 3 components × 2 replicas × 200m CPU limit = 1.2 CPU steady-state. Rolling updates need headroom — keep quota ≥ 2× peak component count × limit.

### Platform Module inputs (`main.tf`)

```hcl
module "k8s" {
  source = "../terraform-minikube-k8s"

  cluster_name  = var.cluster_name
  memory        = var.memory          # default 6144 MB in terraform.tfvars
  cni           = "flannel"           # flannel required on macOS Docker driver
  service_cidr  = "10.96.0.0/12"     # must match what minikube actually starts with
  dns_ip        = "10.96.0.10"        # must match kube-dns ClusterIP
  ...
}
```

> **Why 10.96.x.x?** minikube ignores `kubeadm.service-cluster-ip-range` extra_config and always starts kube-apiserver with `10.96.0.0/12`. The `dns_ip` must match the real kube-dns ClusterIP or pods get a broken nameserver.

## `./tf` wrapper

The `tf` script wraps `terraform` to load `.env` as `TF_VAR_*` exports and adds the `bootstrap` subcommand:

```
./tf plan
./tf apply -auto-approve
./tf bootstrap          # reset local minikube profile + local tf state, purge stale Cloudflare tunnel, then full apply
./tf output -json grafana_credentials
```

## Development

```bash
terraform fmt -recursive
terraform validate
./tf plan
```

---

**Built as a real internal developer platform.**

License: MIT
