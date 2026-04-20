# Platform Architecture

## Repository Layout

```
terraform-minikube-platform/
├── main.tf                  # Module wiring (k8s, addons, project)
├── platform.tf              # Root-owned `platform` namespace + its ResourceQuota
├── mysql.tf, postgres.tf,   # Shared services (toggled via config/platform.yaml)
│ redis.tf, ollama.tf
├── variables.tf             # Input variables
├── locals.tf                # YAML loading + project expansion
├── outputs.tf               # Platform outputs + cheatsheet
├── cloudflare.tf            # Tunnel + DNS (fully dynamic from project outputs)
├── cloudflared.tf           # cloudflared Deployment + Secret in `ops` namespace
├── _providers.tf            # All provider configs (cloudflare, kubernetes, kubectl, helm)
├── _versions.tf             # Provider version constraints
├── _backend.tf              # State backend (local or remote S3)
├── tf                       # Wrapper script: loads .env, bootstrap-minikube / bootstrap-k3s / cloudflare-purge
├── config/
│   ├── platform.yaml        # Which shared services to deploy (gitignored; `.example` is tracked)
│   ├── domains/             # One YAML per tenant domain (gitignored — contains zone IDs)
│   ├── components/          # Reusable component definitions (tracked)
│   └── limits/<ns>.yaml     # Per-namespace ResourceQuota; `default.yaml` is the fallback
└── modules/
    ├── project/             # Namespace + quota + DB/Postgres/Redis/Ollama hookup + components + IR + BasicAuth Middleware
    ├── component/           # Deployment + Service + PV/PVC + ConfigMap + chown init
    ├── mysql/               # MySQL StatefulSet + Secret + PV (toggle: services.mysql.enabled)
    ├── postgres/            # PostgreSQL StatefulSet + Secret + PV (toggle: services.postgres.enabled)
    ├── redis/               # Redis StatefulSet + PV, ACL-ready (toggle: services.redis.enabled)
    └── ollama/              # Ollama StatefulSet + PV + model-pull Job (toggle: services.ollama.enabled)
```

## Three-Layer Module Stack

The platform composes three upstream Terraform modules (all fetched from GitHub at pinned tags):

1. **Cluster** — `terraform-minikube-k8s` (minikube) OR `terraform-k3s-k8s` (native k3s over SSH). Same signature (`kubeconfig_path`, `cluster_*`, cert attrs), so the layers above are distribution-agnostic.
2. **Addons** — `terraform-k8s-addons` — Traefik, cert-manager + Let's Encrypt, kube-prometheus-stack, PSS-labeled namespaces with default ResourceQuota + LimitRange.
3. **Tenant workloads** (this repo) — platform namespace + its shared services, per-project namespaces with components, Cloudflare tunnel + DNS.

## Assembly Flow

```
config/platform.yaml          → local.platform.services.{mysql,postgres,redis,ollama}.{enabled,...}
config/domains/*.yaml         → local.projects (domain × env expansion; routes map)
config/components/*.yaml      → local.components
config/limits/*.yaml          → local.namespace_limits (keyed by namespace name)

main.tf
  → module.k8s_k3s["enabled"] OR module.k8s_minikube["enabled"]  (cluster; picked by var.distribution)
  → module.addons             (Traefik + cert-manager + monitoring + namespaces)
  → module.project (for_each) (per tenant)

platform.tf
  → kubernetes_namespace_v1.platform
  → kubernetes_resource_quota_v1.platform  (limits from config/limits/platform.yaml)

mysql.tf / postgres.tf / redis.tf / ollama.tf
  → module.mysql / .postgres / .redis / .ollama (all keyed off `enabled` flag from platform.yaml)

cloudflare.tf
  → cloudflare_zero_trust_tunnel_cloudflared + its config
  → cloudflare_record for every routed hostname (collected from module.project[*].hostnames)

modules/project/main.tf
  → kubernetes_namespace_v1
  → kubernetes_resource_quota_v1 (from config/limits/<ns>.yaml → default.yaml → domain.limits)
  → kubernetes_job_v1   mysql_setup     (gated: any component has `db: true`)
  → kubernetes_secret_v1  db-credentials
  → kubernetes_job_v1   postgres_setup  (gated: any component has `postgres: true`)
  → kubernetes_secret_v1  postgres-credentials
  → kubernetes_job_v1   redis_setup     (gated: any component has `redis: true`)
  → kubernetes_secret_v1  redis-credentials
  → kubernetes_secret_v1  ollama-endpoint (gated: any component has `ollama: true`)
  → kubernetes_secret_v1  <component>-random-env  (for every env_random entry)
  → kubernetes_secret_v1  <component>-basic-auth  + kubectl_manifest Middleware  (basic_auth: true)
  → module.component (for each deployable component)
  → kubectl_manifest ingressroute (per component, services differ by kind)

modules/component/main.tf
  → kubernetes_persistent_volume_v1 + PVC  (hostPath at <volume_base_path>/<ns>/<name>/<slug>)
  → kubernetes_config_map_v1 (config_files)
  → kubernetes_deployment_v1
     (init container `chown-volumes` when security.fs_group is set)
     (env_from: db-credentials, redis-credentials, ollama-endpoint, <comp>-random-env)
     (env: static_env map)
     (pod.security_context: run_as_user, fs_group)
     (startup_probe → liveness_probe → readiness_probe)
  → kubernetes_service_v1
```

## Module Responsibility Split

| Module | Responsibility |
|---|---|
| `platform.tf` (root) | Owns the `platform` namespace + its ResourceQuota. |
| `modules/mysql` | MySQL StatefulSet + Secret + PV/PVC. No namespace. |
| `modules/redis` | Redis StatefulSet + PV/PVC + default-user Secret. No namespace. |
| `modules/ollama` | Ollama StatefulSet + PV/PVC + model-pull Job. No namespace. |
| `modules/project` | Tenant namespace + quota + DB/Redis/Ollama hookup + component orchestration + BasicAuth middleware + IngressRoutes. |
| `modules/component` | Deployment + Service + PV/PVC + ConfigMap + chown init. No routing, no namespace. |
| `cloudflare.tf` | Tunnel resource, ingress rules (for each hostname from `module.project[*].hostnames`), DNS CNAME records, force-delete-on-destroy fallback. |
| `cloudflared.tf` | cloudflared Deployment + token Secret in the `ops` namespace (created by the addons module). |

## Route Model

Domain YAML:

```yaml
envs:
  <env_name>:
    routes:
      <host_prefix>: <component_name>
```

- `<host_prefix> == ""` → apex (bare domain)
- `<host_prefix> == "www"` → `www.{domain}`
- `<host_prefix> == "api.dev"` → `api.dev.{domain}` (env is NOT auto-injected; operator writes the full prefix)

A component is **deployed** iff it appears as a route value at least once. Hostname set per component = every route that points at that component. One IngressRoute per component with `match = Host(a) || Host(b) || …`.

Components can be `kind: deployment` (this repo owns the workload) or `kind: external` (route-only to a pre-existing cluster Service, with optional `ingress_service:` override for Traefik-internal targets like `api@internal`).

## Shared Services (platform namespace)

All three live in the root-owned `platform` namespace (ResourceQuota from `config/limits/platform.yaml`, fat because Ollama alone can saturate 10 CPU).

**MySQL** (`services.mysql.enabled`):
- StatefulSet, 1 replica, hostPath PV (`<host_volume_path>/platform/mysql/`)
- Root password: `random_password` in the `mysql-root` Secret
- Per-tenant hook: a Kubernetes Job in the tenant namespace runs `mysql -u root -e "CREATE DATABASE … CREATE USER … GRANT …"`; result lands in `db-credentials` Secret. DB is NOT dropped on destroy.

**Redis** (`services.redis.enabled`):
- StatefulSet, 1 replica, AOF persistence, ACL enabled
- `default` user password: `random_password` in the `redis-default` Secret
- Per-tenant hook: a Job runs `redis-cli ACL SETUSER <namespace> on >… resetkeys ~<namespace>:* +@all -@dangerous`; result lands in `redis-credentials` Secret with `REDIS_USER` / `REDIS_PASSWORD` / `REDIS_KEY_PREFIX`. Key prefix gives real cross-tenant isolation (a tenant literally cannot read another's keys).

**Ollama** (`services.ollama.enabled`):
- StatefulSet, 1 replica, hostPath PV (`<host_volume_path>/platform/ollama/`)
- `/api/tags` probe on port 11434
- Model-pull Job runs `ollama pull <model>` for every entry in `services.ollama.models` after the server is ready. Idempotent — re-applies are free for already-cached models. Name hashes the model list, so a list change rotates the Job.
- No auth. Tenants address it via `OLLAMA_HOST` / `OLLAMA_BASE_URL` / `OLLAMA_API_BASE` env vars injected through the per-tenant `ollama-endpoint` Secret.

## Bootstrap Flow (k3s — `var.distribution="k3s"`, the default)

```
./tf bootstrap-k3s
  Step 0:    terraform destroy -auto-approve
  Step 0.5:  Force-uninstall k3s over SSH (no-op if already gone)
  Step 0.25: rm local terraform.tfstate / backup / .terraform.lock.hcl
  Step 0.5:  Purge the platform's Cloudflare tunnel + its DNS records (scoped by tunnel UUID, never touches unrelated DNS)
  Step 1:    terraform apply -auto-approve (single phase — providers open kubeconfig_path lazily)
```

`./tf bootstrap-minikube` is the same flow against a minikube profile — set `TF_VAR_distribution=minikube` before running.

## Why IngressRoute Uses kubectl_manifest

| Provider | Plan behaviour |
|---|---|
| `hashicorp/kubernetes_manifest` | Queries cluster API during plan → fails on fresh cluster before Traefik CRDs exist. |
| `gavinbunney/kubectl_manifest` | Passes YAML as-is, no CRD lookup at plan time. |

## Cloudflare Tunnel Wiring

```
Internet → Cloudflare edge
  → DNS CNAME: <hostname> → <tunnel-id>.cfargotunnel.com
  → Tunnel ingress rule: <hostname> → <service URL>

cloudflared pod (ops namespace, 2 replicas)
  → connects using JWT token from the tunnel resource (not the tunnel secret)
  → proxies requests to the Service URL listed in the ingress rule
```

**Service URL per component kind:**
- `kind: deployment` → `http://<component>.<tenant_ns>.svc:<port>` (direct to workload, bypasses Traefik)
- `kind: external` → `http://<service.name>.<service.namespace>.svc:<service.port>` (direct to the pre-existing Service)
- `ingress_service: {kind: TraefikService}` → still forwards to Traefik's own Service; the IngressRoute at `web` entry point completes routing to `api@internal`.

**Force-delete on destroy:** a `null_resource` with a `when = destroy` local-exec hits the Cloudflare API with `DELETE /cfd_tunnel/<id>?force=true` on a 30 s curl timeout. The provider-level destroy then finds the tunnel already gone and returns quickly instead of blocking for the 3–5 minute "active connections" retry.

## Storage Model

Every persistent volume is a `hostPath` rooted at `var.host_volume_path`, passed through the project / platform-service / component modules as `volume_base_path`:

```
Node FS:     <host_volume_path>/<namespace>/<component>/<slug>/
Pod mount:   /<mount-path>
```

`<slug>` = mount path with leading `/` trimmed and internal `/` replaced with `-`. Example: `/var/www/html/wp-content` → `var-www-html-wp-content`.

For non-root images (WordPress = UID 33, Redis = UID 999, Open WebUI = UID 1000) the component pod gets a `chown-volumes` init container that runs as root and recursively chowns every mounted volume to `fs_group`. The pod itself still runs as `run_as_user`.

## Security

- **BasicAuth** — component opts in via `basic_auth: true`. Per-tenant `random_password` (32 chars, bcrypt-hashed for htpasswd), a namespace-scoped Secret + Traefik `Middleware` of `kind: BasicAuth`, and the Middleware is attached to the component's IngressRoute. Plaintext available through `terraform output basic_auth`.
- **env_random** — component declares `env_random: [KEY1, KEY2]`. Terraform generates a `random_password` per key, stores them in a namespace-scoped `<component>-random-env` Secret, env_from'd into the container. Values persist in state (so the app's internal JWT signing key survives restarts), stay out of YAML (so nothing is committed to git).
- **Cross-namespace IngressRoutes** — the addons module enables `providers.kubernetesCRD.allowCrossNamespace=true` on Traefik so a tenant IR can cross-reference a Service in `monitoring` or `platform`. That setting applies cluster-wide, so this is a platform-level trust decision — all tenants can route at all cluster Services.

## Networking

- **CNI**: Flannel (both distributions; `pod_cidr` hardcoded on minikube, configurable on k3s)
- **Service CIDR**: `100.64.0.0/12` (CGNAT range, avoids LAN collisions)
- **Traefik**: Helm chart in `ingress-controller` namespace, LoadBalancer Service
- **Cloudflare Tunnel**: replaces any LoadBalancer IP for external access; the host never needs open ports

## Known Limitations

- Single-node only (minikube or a single k3s server). For multi-node k3s, the hostPath model has to be replaced with a network-backed StorageClass (longhorn, nfs-subdir, etc.).
- Re-bootstrap regenerates every credential in state (MySQL root, Redis default, component BasicAuth) but persistent hostPath data retains the old credentials. Wipe the relevant `<host_volume_path>/<namespace>/<component>/` dir to reset.
- `host_volume_path` is distribution-coupled: the value must match how the kubelet sees the FS (native-Linux k3s and `--driver=none` minikube use a regular host dir; macOS Docker-driver minikube uses `/minikube-host/...` because it auto-mounts `/Users`; Linux Docker-driver minikube needs an explicit `minikube mount`).
