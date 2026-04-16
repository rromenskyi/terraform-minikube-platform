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

### External dependency

This repo uses `../terraform-minikube-k8s` (sibling checkout) for the base cluster. Clone both:

```bash
cd ~/minikube   # or your preferred directory
git clone <terraform-minikube-k8s-repo>
git clone <terraform-minikube-platform-repo>
```

### Alternative cluster distribution: k3s

The cluster module is swappable. `main.tf` has an **Option A — minikube** (active) and **Option B — k3s** (commented out) block. Both modules export the same output signature (`cluster_host`, `client_certificate`, `client_key`, `cluster_ca_certificate`, `grafana_credentials`, `kubeconfig_path`, …), so everything below the cluster block (providers, MySQL, Cloudflare tunnel, project modules) is distribution-agnostic.

To switch to k3s (native install via SSH):

1. In `main.tf`, comment out the Option A block and uncomment Option B.
2. Clone the sibling checkout: `git clone <terraform-k3s-k8s-repo>` next to this repo.
3. In `.env`, set `TF_VAR_ssh_user` and `TF_VAR_ssh_private_key_path` (see `.env.example`).
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

# Persistent volumes (hostPath on Mac, survives cluster re-creation)
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

Data is stored on the Mac host at `/Users/Shared/vol/` (configurable via `host_volume_path` variable). Minikube Docker driver mounts `/Users` into the node at `/minikube-host`, so the data persists across cluster re-creations.

```
/Users/Shared/vol/
├── platform/mysql/                          # MySQL data directory
├── example-org-prod/wordpress/
│   └── var-www-html-wp-content/             # WordPress uploads, plugins, themes
├── example-com-prod/wordpress/
│   └── var-www-html-wp-content/
└── ...
```

**Important**: `./tf bootstrap` resets the cluster and Terraform state but does NOT delete host volumes. Data survives.

**Gotcha**: On re-bootstrap, MySQL root password is regenerated (new state = new `random_password`), but the existing data directory retains the old password. If this happens, clear MySQL data:
```bash
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

This deletes the Minikube cluster, resets Terraform state, purges Cloudflare tunnel + DNS, and rebuilds everything. Host volume data at `/Users/Shared/vol/` is preserved.

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
| `host_volume_path` | `/Users/Shared/vol` | Mac host directory for persistent data |

## Known limitations

- **Single-node only**: Minikube runs one node. Not for production.
- **Re-bootstrap password mismatch**: On `./tf bootstrap`, MySQL root password is regenerated but persistent data retains the old one. Clear MySQL data dir manually if needed.
- **macOS only**: hostPath storage relies on Docker Desktop's `/Users` mount. Linux would need a different path.
- **No CI/CD**: `./tf bootstrap` uses `-auto-approve`. Add manual review gates for team use.

## License

MIT
