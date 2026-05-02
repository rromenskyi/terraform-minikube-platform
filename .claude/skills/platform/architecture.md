# platform — architecture

## Three-layer module stack

```
1. Cluster layer       terraform-k3s-k8s (Option B, current) OR
                       terraform-minikube-k8s (Option A, legacy)
                       Same signature → distribution-agnostic upstream

2. Addons layer        terraform-k8s-addons
                       Traefik, cert-manager + Let's Encrypt,
                       kube-prometheus-stack, PSS-labeled namespaces
                       with default ResourceQuota + LimitRange

3. Tenant layer        ~/platform (this repo)
                       platform namespace + shared services,
                       per-project namespaces with components,
                       Cloudflare tunnel + DNS
```

All three pinned by tag in `main.tf`. Bumping a layer = bumping the source ref in main.tf, then `terraform apply`.

## Repository layout (~/platform)

```
~/platform/
├── main.tf                  # Module wiring (k8s, addons, project for_each)
├── platform.tf              # Root-owned `platform` namespace + ResourceQuota
├── mysql.tf, postgres.tf,   # Shared services — toggled via config/platform.yaml
│   redis.tf, ollama.tf
├── cloudflare.tf            # Tunnel + per-host DNS records (dynamic from project outputs)
├── cloudflared.tf           # cloudflared Deployment + Secret in `ops` namespace
├── _providers.tf            # cloudflare, kubernetes, kubectl, helm provider configs
├── _versions.tf             # Provider version constraints
├── _backend.tf              # State backend (B2/S3 remote OR local override)
├── tf                       # Wrapper script: loads .env, bootstrap-*, cloudflare-purge
├── config/
│   ├── platform.yaml        # Which shared services to deploy (gitignored)
│   ├── platform.yaml.example
│   ├── domains/             # One YAML per tenant domain (gitignored — has zone IDs)
│   ├── components/          # Reusable component definitions (tracked)
│   └── limits/<ns>.yaml     # Per-namespace ResourceQuota; `default.yaml` fallback
└── modules/
    ├── project/             # Tenant namespace + quota + DB/Postgres/Redis/Ollama hooks + components + IngressRoutes
    ├── component/           # Deployment + Service + PV/PVC + ConfigMap + chown init + sidecars
    ├── mysql/               # MySQL StatefulSet + per-tenant DB+user provisioning Job
    ├── postgres/            # PostgreSQL StatefulSet + per-tenant DB+role provisioning Job
    ├── redis/               # Redis StatefulSet + per-tenant ACL user + key prefix
    └── ollama/              # Ollama StatefulSet + model-pull Job (toggled by platform.yaml)
```

## Per-tenant namespace model

```
phost-<domain-slug>-<env>
  ├─ ResourceQuota                  (limits/<ns>.yaml → default.yaml fallback)
  ├─ Secret: db-credentials         (when any component has db: true)
  ├─ Secret: postgres-credentials   (when any component has postgres: true)
  ├─ Secret: redis-credentials      (when any component has redis: true)
  ├─ Secret: ollama-endpoint        (when any component has ollama: true)
  ├─ Secret: <component>-random-env (per env_random: list)
  ├─ Secret: <component>-basic-auth + Middleware (when basic_auth: true)
  ├─ Job: mysql_setup / postgres_setup / redis_setup (idempotent, gated)
  ├─ <component> Deployment + Service + PV/PVC + ConfigMap (per deployable component)
  ├─ <component> sidecars in same Pod (mcp-weather, open-terminal, ...)
  └─ IngressRoute (per component, Host(a) || Host(b) || ...)
```

Naming: `phost-<slug>-<env>`, e.g. `phost-example-com-prod`.

## Route model

Domain YAML:

```yaml
envs:
  <env_name>:
    routes:
      <host_prefix>: <component_name>
```

- `<host_prefix> == ""` → apex (bare domain)
- `<host_prefix> == "www"` → `www.{domain}`
- `<host_prefix> == "api.dev"` → `api.dev.{domain}` (env NOT auto-injected)

A component is **deployed** iff it appears as a route value at least
once. Hostname set per component = every route that points at it. One
IngressRoute per component with `match = Host(a) || Host(b) || …`.

`kind: deployment` — this repo owns the workload. `kind: external` —
route-only to a pre-existing cluster Service (Grafana in `monitoring`,
Traefik dashboard via `api@internal`, Ollama in `platform`); optional
`ingress_service:` override for Traefik-internal targets.

## Shared services (platform namespace)

All in the root-owned `platform` namespace. Quota at `config/limits/platform.yaml` (12 CPU / 24 Gi on this workstation; Ollama alone can burn 10 CPU during inference).

### MySQL (`services.mysql.enabled`)
- StatefulSet, 1 replica, hostPath PV.
- Root password: `random_password` in `mysql-root` Secret.
- Per-tenant: Job runs `CREATE DATABASE / CREATE USER / GRANT`. Result → `db-credentials` Secret in tenant ns. DB NOT dropped on destroy.

### PostgreSQL (`services.postgres.enabled`)
- StatefulSet, 1 replica, hostPath PV.
- Superuser: `postgres-superuser` Secret.
- Per-tenant: psql Job creates DB + role. Secret: `postgres-credentials` (`PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USER`, `PG_PASSWORD`, `DATABASE_URL`).

### Redis (`services.redis.enabled`)
- StatefulSet, 1 replica, AOF persistence, ACL enabled.
- `default` user password: `redis-default` Secret.
- Per-tenant: Job runs `ACL SETUSER <namespace> on >... resetkeys ~<namespace>:* +@all -@dangerous`. Secret: `redis-credentials` (`REDIS_USER`, `REDIS_PASSWORD`, `REDIS_KEY_PREFIX`, `REDIS_HOST`, `REDIS_PORT`). Key prefix = real cross-tenant isolation.

### Ollama (`services.ollama.enabled`)
- StatefulSet, 1 replica, hostPath PV at `<host_volume_path>/platform/ollama/`.
- `/api/tags` probe on port 11434.
- Model-pull Job runs `ollama pull <model>` for every entry in `services.ollama.models` after server is ready. Idempotent. Name hashes the models list, so list change rotates the Job.
- No auth. Tenants address via `OLLAMA_HOST` / `OLLAMA_BASE_URL` / `OLLAMA_API_BASE` injected through per-tenant `ollama-endpoint` Secret.
- **GPU backend** — see operating.md (Vulkan + Arc B50 specifics).

## Component model (modules/component)

Single `Deployment` + `Service` per component. Optional:
- `storage:` — list of `{mount, size}` → hostPath PV/PVC per mount.
- `config_files:` → ConfigMap mounted into container.
- `env_static:` — literal env values from YAML.
- `env_random:` — Terraform-generated random_password per key, in `<component>-random-env` Secret. Persists in TF state (so JWT keys survive restart); never in YAML.
- `security: { run_as_user, fs_group }` + auto `chown-volumes` init container for hostPath mounts.
- `basic_auth: true` — random_password, htpasswd, namespace-scoped Secret + Traefik Middleware. Plaintext via `terraform output basic_auth`.
- `sidecars:` — additional containers in the same Pod (loopback only, no Service ports). Used for MCP servers, terminals, helper daemons. Each sidecar gets its own `image`, optional `command/args`, `env_static`, `env_random`, `writable_paths` (per-sidecar emptyDir), `resources`, `security`. Defaults: `run_as_user: 1000`, `read_only_root_filesystem: true`.
- `ollama: true` / `db: true` / `postgres: true` / `redis: true` — opt into the corresponding shared service.
- `image_pull_policy:` — explicit override. Auto-derives like Kubernetes' default: moving tag (`:latest`, empty) → `Always`; pinned tag/digest → `IfNotPresent`.

## Cloudflare Tunnel wiring

```
Internet
  └─▶ Cloudflare edge
        ├─▶ DNS CNAME: <hostname> → <tunnel-id>.cfargotunnel.com
        └─▶ Tunnel ingress rule: <hostname> → <service URL>

cloudflared (ops namespace, 2 replicas)
  └─▶ JWT token from tunnel resource (NOT the tunnel secret)
       └─▶ Proxies to the Service URL listed in the ingress rule
```

Service URL per component kind:
- `kind: deployment` → `http://<component>.<tenant_ns>.svc:<port>` (direct, bypasses Traefik)
- `kind: external` → `http://<service.name>.<service.namespace>.svc:<service.port>` (direct)
- `ingress_service: {kind: TraefikService}` → still forwards to Traefik's Service; the IngressRoute at `web` entry point completes routing to e.g. `api@internal`.

**Force-delete on destroy**: a `null_resource` with `when = destroy` local-exec hits `DELETE /cfd_tunnel/<id>?force=true` with 30s curl timeout. Without this, the provider blocks 3-5 minutes waiting for active connections to clear.

## Networking

- **CNI**: Flannel on both distributions.
- **Pod CIDR**: `100.72.0.0/16` on minikube (CGNAT, avoids podman-bridge `10.244.0.1` collision); `10.42.0.0/16` on k3s (k3s default).
- **Service CIDR**: `100.64.0.0/20` on minikube; `10.43.0.0/16` on k3s.
- **Traefik**: Helm chart in `ingress-controller` namespace, LoadBalancer Service.
- **Cloudflare Tunnel**: replaces any LoadBalancer external IP — host never needs open ports.

## Why kubectl_manifest for IngressRoutes (not kubernetes_manifest)

`hashicorp/kubernetes_manifest` queries the cluster API at plan time → fails on a fresh cluster before Traefik CRDs exist. `gavinbunney/kubectl_manifest` passes YAML as-is, no CRD lookup at plan. Critical for single-phase bootstrap.

## Module responsibility split

| Module | Responsibility |
|---|---|
| `platform.tf` (root) | Owns the `platform` namespace + its ResourceQuota. |
| `modules/mysql` | MySQL StatefulSet + Secret + PV/PVC. NO namespace creation. |
| `modules/redis` | Redis StatefulSet + PV/PVC + default-user Secret. NO namespace. |
| `modules/ollama` | Ollama StatefulSet + PV/PVC + model-pull Job. NO namespace. |
| `modules/project` | Tenant namespace + quota + DB/Redis/Ollama hookup + component orchestration + BasicAuth Middleware + IngressRoutes. |
| `modules/component` | Deployment + Service + PV/PVC + ConfigMap + chown init + sidecars. NO routing, NO namespace. |
| `cloudflare.tf` | Tunnel resource, ingress rules (per hostname from `module.project[*].hostnames`), DNS CNAMEs, force-delete-on-destroy fallback. |
| `cloudflared.tf` | cloudflared Deployment + token Secret in `ops`. |

## Known limitations

- **Single-node only** (minikube or single k3s server). Multi-node k3s requires replacing the hostPath model with a network-backed StorageClass (longhorn, nfs-subdir, etc.).
- **Re-bootstrap regenerates every credential** in TF state. Persistent hostPath data retains old creds → wipe `<host_volume_path>/<namespace>/<component>/` to reset.
- **`host_volume_path` is distribution-coupled**: native k3s and `--driver=none` minikube → regular host dir; macOS Docker-driver minikube → `/minikube-host/...`; Linux Docker-driver minikube → explicit `minikube mount`.
