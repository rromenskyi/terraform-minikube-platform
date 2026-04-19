# terraform-minikube-platform

Terraform-first Kubernetes hosting platform on Minikube. One domain = one YAML file. Zero-trust public access via Cloudflare Tunnel. No port-forwarding, no LoadBalancer, no manual `kubectl`.

## What you get

- **Multi-domain hosting** on a single Minikube cluster
- **Per-project isolation**: separate namespaces, resource quotas, databases
- **Shared MySQL 8.0** with auto-provisioned DB + user per project
- **Cloudflare Tunnel** for public HTTPS access (no open ports on the host)
- **TLS** via Let's Encrypt + cert-manager
- **Traefik** as ingress controller with dashboard
- **Grafana + Prometheus** for monitoring
- **Persistent storage** on the Mac host filesystem (survives cluster re-creation)
- **`./tf bootstrap`** to bring up everything from scratch in one command

## Architecture

```
Internet
  │
  ▼
Cloudflare (DNS + TLS + Tunnel)
  │
  ▼ (tunnel)
cloudflared (2 replicas, ops namespace)
  │
  ▼
Traefik IngressRoute (ingress-controller namespace)
  │
  ├─► web.example.com        → nginx pod
  ├─► whoami.example.com     → whoami pod
  ├─► wordpress.example.com  → wordpress pod ──► MySQL
  ├─► example.com            → wordpress (alias)
  ├─► www.example.com        → wordpress (alias)
  ├─► grafana.example.com    → Grafana
  └─► traefik.example.com    → Traefik dashboard
```

### Module structure

```
terraform-minikube-platform/
├── main.tf                     # Wires k8s, mysql, project modules
├── cloudflare.tf               # Tunnel + DNS (fully dynamic from project outputs)
├── cloudflared.tf              # cloudflared Deployment in ops namespace
├── traefik-dashboard.tf        # Traefik dashboard IngressRoute
├── mysql.tf                    # Shared MySQL module
├── variables.tf, locals.tf     # Platform configuration
├── outputs.tf                  # Projects, hostnames, credentials, cheatsheet
├── _backend.tf                 # State backend (local or remote)
├── _providers.tf               # Provider config (Cloudflare, Kubernetes, Helm)
├── _versions.tf                # Provider version constraints
├── tf                          # Bootstrap wrapper script
├── config/
│   ├── domains/*.yaml          # Domain configs (one file per domain)
│   ├── components/*.yaml       # Reusable component definitions
│   └── limits/default.yaml     # Default resource quota
└── modules/
    ├── project/                # Namespace + quota + DB + components + IngressRoutes
    ├── component/              # Deployment + Service + PV/PVC + ConfigMap
    └── mysql/                  # Shared MySQL StatefulSet + Secret
```

### External dependencies

Three sibling modules are fetched directly from GitHub at pinned releases — no sibling checkout required:

- Layer 1 (cluster bootstrap, pick ONE):
  - [`terraform-minikube-k8s`](https://github.com/rromenskyi/terraform-minikube-k8s) — Option A (minikube), pinned to `v3.0.0`
  - [`terraform-k3s-k8s`](https://github.com/rromenskyi/terraform-k3s-k8s) — Option B (k3s, active default), pinned to `v0.3.1`
- Layer 2 (platform addons): [`terraform-k8s-addons`](https://github.com/rromenskyi/terraform-k8s-addons) — pinned to `v0.1.0`

`terraform init` downloads the selected modules automatically. To upgrade, bump the `?ref=vX.Y.Z` in `main.tf` and re-run `terraform init -upgrade`.

### Alternative cluster distribution

The cluster module is swappable. `main.tf` has an **Option A — minikube** (commented out) and **Option B — k3s** (active default) block. Both modules export the same output signature (`cluster_host`, `client_certificate`, `client_key`, `cluster_ca_certificate`, `kubeconfig_path`, `cluster_name`, `cluster_distribution`), so layers 2 and 3 (addons, MySQL, Cloudflare tunnel, project modules) are distribution-agnostic.

To switch to k3s (native install via SSH):

1. In `main.tf`, comment out the Option A block and uncomment Option B.
2. In `.env`, set `TF_VAR_ssh_user` and `TF_VAR_ssh_private_key_path` (see `.env.example`).
3. `terraform init -upgrade` to pull the k3s module.
4. `./tf apply` — the root `kubernetes` and `helm` providers lazily open `module.k8s.kubeconfig_path`, so a single apply is enough (no two-phase `-target` bootstrap).

Switching between distributions on a live state recreates the cluster — the underlying resources are different module sources.

## Prerequisites

- **Docker Desktop** (Minikube uses Docker driver on macOS)
- **Minikube** (`brew install minikube`)
- **Terraform** >= 1.5.0 (`brew install terraform`)
- **kubectl** (`brew install kubectl`)
- **jq** (`brew install jq`)
- **Cloudflare account** with at least one domain

## Quick start

### 1. Configure secrets

```bash
cp .env.example .env
```

Edit `.env` and fill in:

```bash
CLOUDFLARE_API_TOKEN=your-token          # API token (not Global API key)
CLOUDFLARE_ACCOUNT_ID=your-account-id
CLOUDFLARE_ZONE_ID=your-primary-zone-id  # Zone ID of the "infra" domain
CLOUDFLARE_TUNNEL_SECRET=any-random-32-char-string
LETSENCRYPT_EMAIL=your-email@example.com
```

### 2. Configure your domains

```bash
cp config/domains/example.com.yaml.example config/domains/mydomain.com.yaml
```

Edit the file with your domain details (see [Domain configuration](#domain-configuration) below).

### 3. Create terraform.tfvars

```bash
cat > terraform.tfvars <<'EOF'
cloudflare_account_id = "your-account-id"
cloudflare_zone_id    = "your-primary-zone-id"
cluster_name          = "minikube"
memory                = 6144
letsencrypt_email     = "your-email@example.com"
EOF
```

### 4. Bootstrap

```bash
./tf bootstrap
```

This will:
1. Delete any existing Minikube profile and Terraform state
2. Purge stale Cloudflare tunnels and DNS records
3. Create the Minikube cluster
4. Fix CNI networking (Flannel vs podman bridge)
5. Deploy shared MySQL and wait for it to be ready
6. Deploy all projects, components, Cloudflare tunnel, and DNS records

After bootstrap, your sites are live at `https://<component>.<domain>`.

### 5. Verify

```bash
terraform output -json projects | jq .
terraform output -json hostnames | jq .
terraform output cheatsheet
```

## Cloudflare setup guide

### Where to find your credentials

1. **Account ID**: [Cloudflare Dashboard](https://dash.cloudflare.com) > any domain > right sidebar > "Account ID"

2. **Zone ID**: Dashboard > select domain > right sidebar > "Zone ID". Each domain has its own Zone ID.

3. **API Token**: Dashboard > My Profile > API Tokens > Create Token:
   - **Permissions needed**:
     - Zone > Zone > Read
     - Zone > DNS > Edit
     - Account > Cloudflare Tunnel > Edit
     - Account > Zero Trust > Edit
   - **Zone Resources**: Include > All zones (or specific zones)
   - Copy the token immediately (shown only once)

4. **Tunnel Secret**: Any random string, at least 32 characters. Generate one:
   ```bash
   openssl rand -hex 32
   ```

### How to add a domain to Cloudflare

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com) > Add a Site
2. Enter your domain name, select the Free plan
3. Cloudflare shows you two nameservers (e.g. `ada.ns.cloudflare.com`)
4. Go to your domain registrar and change NS records to point to Cloudflare's nameservers
5. Wait for DNS propagation (usually 5-30 minutes, sometimes up to 24h)
6. Once active, copy the **Zone ID** from the dashboard sidebar
7. Create a domain YAML in `config/domains/yourdomain.yaml`:
   ```yaml
   name: yourdomain.com
   slug: yourdomain-com
   cloudflare_zone_id: "paste-zone-id-here"
   envs:
     - prod
   components:
     - web
   ```
8. Run `./tf apply`

### How to add a new domain to an existing platform

```bash
# 1. Create the domain config
cat > config/domains/newdomain.com.yaml <<'EOF'
name: newdomain.com
slug: newdomain-com
cloudflare_zone_id: "zone-id-from-cloudflare-dashboard"
envs:
  - prod
components:
  - web
  - whoami
EOF

# 2. Plan and apply
./tf plan
./tf apply
```

Terraform will create the namespace, deploy components, add tunnel ingress rules, and create DNS CNAME records automatically.

## Configuration

### Domain configuration (`config/domains/*.yaml`)

Each domain gets its own YAML file. Domain configs are gitignored (they contain zone IDs personal to your setup).

```yaml
name: example.com                     # Domain name (used in hostnames)
slug: example-com                     # URL-safe slug (namespace = {prefix}{slug}-{env})
cloudflare_zone_id: "abc123..."       # Cloudflare Zone ID for DNS records

envs:                                 # Environments to create
  - prod
  - staging                           # staging → web.staging.example.com

components:                           # Components to deploy
  - web                               # Simple reference to config/components/web.yaml
  - whoami
  - name: wordpress                   # Extended form with overrides
    aliases:                          # Extra hostnames for this component
      - ""                            # Bare domain (example.com)
      - www                           # www.example.com

limits:                               # (Optional) Namespace resource quota override
  cpu: "4"
  memory: "8Gi"
```

**Hostname generation:**
- Prod: `{component}.{domain}` (e.g. `web.example.com`)
- Non-prod: `{component}.{env}.{domain}` (e.g. `web.staging.example.com`)
- Aliases: `""` = bare domain, `"www"` = `www.{domain}`

### Component configuration (`config/components/*.yaml`)

Reusable component definitions. These are tracked in git.

```yaml
# config/components/web.yaml
image: nginx:alpine
port: 80
replicas: 2
```

Full schema with all options:

```yaml
image: wordpress:6.7-php8.3-apache   # Container image
port: 80                              # Container port
replicas: 1                           # Pod replicas
health_path: null                     # HTTP probe path (null = disable probes)
db: true                              # Provision MySQL database + user
ingress_enabled: true                 # Create IngressRoute (default: true)

# Map app-specific env var names to db-credentials Secret keys
env:
  WORDPRESS_DB_HOST: DB_HOST
  WORDPRESS_DB_NAME: DB_NAME
  WORDPRESS_DB_USER: DB_USER
  WORDPRESS_DB_PASSWORD: DB_PASS

# Persistent volumes (hostPath on the node, survives cluster re-creation)
storage:
  - mount: /var/www/html/wp-content
    size: 10Gi

# Config files mounted into the container (via ConfigMap)
config_files:
  /etc/apache2/conf-enabled/custom.conf: |
    # Apache config content here

# Resource requests/limits (defaults shown)
resources:
  requests: { cpu: "50m",  memory: "64Mi" }
  limits:   { cpu: "200m", memory: "256Mi" }
```

### Resource quotas (`config/limits/default.yaml`)

Default per-namespace quota. Override per-domain in the domain YAML.

```yaml
cpu: "2"
memory: "4Gi"
```

## Persistent storage

One knob — `host_volume_path` — is used **verbatim** as the parent of every `hostPath` PersistentVolume. It must resolve to a real, writable directory from the Kubernetes node's point of view. The correct value depends on how the kubelet sees the filesystem, which differs by distribution:

| Distribution | `host_volume_path` | Why this value |
|---|---|---|
| **Native k3s on Linux** (Option B) | `/data/vol` (or any other host dir) | k3s runs directly on the host; the kubelet sees the host FS 1:1. The path you set is the path the pods bind-mount, and is also where you `ls` from the Linux shell. |
| **minikube on Linux, `--driver=none`** | `/data/vol` (same as k3s) | `--driver=none` is bare-metal minikube; identical semantics to k3s. |
| **minikube on macOS, Docker driver** (Option A default) | `/minikube-host/Shared/vol` | The minikube VM auto-mounts `/Users` from the Mac host as `/minikube-host` inside the node. Put your data at `/Users/Shared/vol` on the Mac and the kubelet sees it as `/minikube-host/Shared/vol`. |
| **minikube on Linux, `--driver=docker`** | a path you bind in explicitly | minikube does **not** auto-mount the host FS under Linux Docker. Run `minikube mount <host-dir>:<node-dir>` and set `host_volume_path=<node-dir>`. |

Data layout under the prefix (same structure on every distribution):

```
{host_volume_path}/
├── platform/mysql/                          # MySQL data directory
├── example-org-prod/wordpress/
│   └── var-www-html-wp-content/             # WordPress uploads, plugins, themes
├── example-com-prod/wordpress/
│   └── var-www-html-wp-content/
└── ...
```

**Important**: `./tf bootstrap` resets the cluster and Terraform state but does NOT delete host volumes. Data survives.

**Gotcha**: On re-bootstrap, MySQL root password is regenerated (new state = new `random_password`), but the existing data directory retains the old password. Clear the MySQL data from wherever it physically lives on the host:
```bash
# native k3s on Linux (default host_volume_path=/data/vol):
sudo rm -rf /data/vol/platform/mysql/*

# macOS minikube (files live at /Users/Shared/vol on the Mac, /minikube-host/... inside the node):
docker exec minikube sh -c 'rm -rf /minikube-host/Shared/vol/platform/mysql/*'
```

## Remote state

By default, state is stored locally in `terraform.tfstate`. For remote state on Backblaze B2 (S3-compatible):

### 1. Create a B2 bucket

1. Sign up at [backblaze.com](https://www.backblaze.com/cloud-storage)
2. Create a bucket (e.g. `myplatform-tfstate`), keep it **private**
3. Create an Application Key with read/write access to the bucket
4. Note the `keyID` (= `AWS_ACCESS_KEY_ID`) and `applicationKey` (= `AWS_SECRET_ACCESS_KEY`)

### 2. Configure the backend

Edit `_backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket                      = "myplatform-tfstate"
    key                         = "platform/terraform.tfstate"
    region                      = "us-east-005"
    endpoint                    = "https://s3.us-east-005.backblazeb2.com"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
```

### 3. Add credentials to `.env`

```bash
AWS_ACCESS_KEY_ID=your-b2-key-id
AWS_SECRET_ACCESS_KEY=your-b2-application-key
```

### 4. Migrate state

```bash
./tf init -migrate-state
```

## The `./tf` wrapper

The `tf` script wraps `terraform` with two features:
1. Loads `.env` variables as `TF_VAR_*` exports
2. Provides the `bootstrap` subcommand for phased cluster setup

```bash
./tf plan                    # terraform plan
./tf apply                   # terraform apply (prompts for confirmation)
./tf apply -auto-approve     # terraform apply without prompt
./tf output -json projects   # terraform output
./tf bootstrap               # Full reset + phased apply
```

### Why phased bootstrap?

Terraform can't create resources that depend on a cluster that doesn't exist yet. The bootstrap flow handles this:

1. Create cluster (`module.k8s.minikube_cluster`)
2. Fix CNI (Flannel vs podman bridge conflict on Docker driver)
3. Deploy MySQL and wait for readiness
4. Apply everything else (projects, tunnel, DNS)

## Common operations

### Add a domain

1. Add domain to Cloudflare, get Zone ID
2. Create `config/domains/yourdomain.yaml`
3. `./tf apply`

### Add a component

1. Create `config/components/myapp.yaml` with image, port, replicas
2. Add `myapp` to your domain's `components` list
3. `./tf apply`

### Add WordPress to a domain

```yaml
# config/domains/mydomain.yaml
components:
  - web
  - name: wordpress
    aliases:
      - ""      # mydomain.com
      - www     # www.mydomain.com
```

WordPress gets: MySQL database, persistent storage for wp-content, IngressRoute with aliases, env var mapping to connect to DB.

### Add a staging environment

```yaml
# config/domains/mydomain.yaml
envs:
  - prod
  - staging
```

This creates a separate namespace `mydomain-com-staging` with all the same components, accessible at `web.staging.mydomain.com`, etc.

### View credentials

```bash
# MySQL root password
terraform output -json mysql | jq -r '.root_password'

# Grafana admin password
terraform output -json grafana_credentials | jq -r '.password'

# Project DB credentials
kubectl get secret db-credentials -n <namespace> -o json | jq '.data | map_values(@base64d)'
```

### Connect to MySQL

```bash
kubectl exec -it statefulset/mysql -n platform -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

### Debug a pod

```bash
kubectl logs -f deploy/wordpress -n example-org-prod
kubectl exec -it deploy/wordpress -n example-org-prod -- bash
kubectl describe pod -l app=wordpress -n example-org-prod
```

### Full re-bootstrap

```bash
./tf bootstrap
```

This deletes the Minikube cluster, resets Terraform state, purges Cloudflare tunnel + DNS, and rebuilds everything. Host volume data under `host_volume_path` (default `/data/vol`) is preserved.

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `minikube` | Minikube profile name |
| `memory` | `4096` | Cluster memory in MB |
| `kubernetes_version` | `v1.34.4` | K8s version |
| `pod_cidr` | `10.244.0.0/16` | Pod IP range (locked to Flannel default) |
| `letsencrypt_email` | *(required)* | Email for Let's Encrypt certificates |
| `cloudflare_api_token` | *(required)* | Cloudflare API token |
| `cloudflare_account_id` | *(required)* | Cloudflare Account ID |
| `cloudflare_tunnel_secret` | *(required)* | Random secret for tunnel creation |
| `cloudflare_zone_id` | *(required)* | Primary zone for infra services (traefik, grafana) |
| `namespace_prefix` | `""` | Optional prefix for all namespaces (e.g. `h-`) |
| `host_volume_path` | `/data/vol` | Parent path for hostPath PVs, used verbatim by the kubelet. Override to `/minikube-host/Shared/vol` for macOS minikube Docker driver. See [Persistent storage](#persistent-storage). |

## Known limitations

- **Single-node only**: Minikube runs one node. Not for production.
- **Re-bootstrap password mismatch**: On `./tf bootstrap`, MySQL root password is regenerated but persistent data retains the old one. Clear MySQL data dir manually if needed.
- **hostPath storage is distribution-coupled**: the `host_volume_path` value must match how the kubelet sees the filesystem (native-Linux k3s/`--driver=none` use a regular host dir; macOS Docker-driver minikube uses `/minikube-host/...` because it auto-mounts `/Users`; Linux Docker-driver minikube needs an explicit `minikube mount`).
- **No CI/CD**: `./tf bootstrap` uses `-auto-approve`. Add manual review gates for team use.

## License

MIT
