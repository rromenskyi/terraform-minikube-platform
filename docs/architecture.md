# Platform Architecture

## Repository Layout

```
terraform-minikube-platform/
├── main.tf                  # Module wiring (k8s, mysql, project)
├── variables.tf             # Input variables
├── locals.tf                # YAML loading + project/component expansion
├── outputs.tf               # Platform outputs + cheatsheet
├── cloudflare.tf            # Tunnel + DNS (fully dynamic from project outputs)
├── cloudflared.tf           # cloudflared Deployment + Secret in ops namespace
├── traefik-dashboard.tf     # Traefik dashboard IngressRoute
├── mysql.tf                 # Shared MySQL module instantiation
├── _providers.tf            # All provider configs (cloudflare, kubernetes, kubectl, helm)
├── _versions.tf             # Provider version constraints
├── _backend.tf              # State backend (local or remote S3)
├── tf                       # Wrapper script: loads .env, adds bootstrap subcommand
├── config/
│   ├── domains/             # One YAML per domain (gitignored — contains zone IDs)
│   ├── components/          # Reusable component defaults (image, port, replicas)
│   └── limits/default.yaml  # Default namespace ResourceQuota
└── modules/
    ├── project/             # Namespace + quota + DB provisioning + components + IngressRoutes
    ├── component/           # Deployment + Service + PV/PVC + ConfigMap
    └── mysql/               # Shared MySQL StatefulSet + Secret + namespace
```

## Assembly Flow

```
locals.tf
  → loads config/domains/*.yaml    → local.projects  (domain × env expansion)
  → loads config/components/*.yaml → local.components
  → loads config/limits/default.yaml → local.default_limits

main.tf
  → module.k8s       (cluster distribution — minikube or k3s sibling; see Option A/B)
  → module.mysql     (shared MySQL in {prefix}platform namespace)
  → module.project   (for_each = local.projects)

cloudflare.tf
  → merges all project hostnames + infra hostnames
  → creates tunnel, ingress rules, DNS CNAMEs — fully dynamic

modules/project/main.tf
  → merges component_defaults + config/components + per-domain overrides
  → kubernetes_namespace_v1 + kubernetes_resource_quota_v1
  → kubernetes_job_v1 (MySQL DB + user provisioning via in-cluster job)
  → kubernetes_secret_v1 (db-credentials)
  → module.component (for each component)
  → kubectl_manifest (IngressRoute per routed component, supports aliases)

modules/component/main.tf
  → kubernetes_persistent_volume_v1 + PVC (hostPath storage)
  → kubernetes_config_map_v1 (config_files)
  → kubernetes_deployment_v1 (with env mapping, probes, volumes, config mounts)
  → kubernetes_service_v1
```

## Module Responsibility Split

| Module | Responsibility |
|---|---|
| `modules/mysql` | Platform namespace, MySQL StatefulSet, root Secret, PV/PVC. |
| `modules/project` | Namespace, ResourceQuota, DB provisioning (Job), db-credentials Secret, component orchestration, IngressRoutes. |
| `modules/component` | Deployment, Service, PV/PVC, ConfigMap. No routing, no namespace concerns. |
| `cloudflare.tf` | Tunnel resource, dynamic ingress rules from all project outputs, DNS CNAME records. |
| `cloudflared.tf` | cloudflared Deployment + token Secret in ops namespace. |

## Bootstrap Flow

```
./tf bootstrap
  Step 0:    Delete local minikube profile metadata
  Step 0.25: Delete local terraform.tfstate / backup / lock
  Step 0.5:  Purge stale Cloudflare tunnel + DNS CNAMEs (all zones)
  Step 1:    terraform apply -target=module.k8s.minikube_cluster.this
  Step 1.5:  Clean stale CNI (cni0, flannel.1), disable podman bridge,
             wait for Flannel, restart kube-system
  Step 1.7:  terraform apply -target=module.mysql, wait for MySQL readiness
  Step 2:    terraform apply (everything else)
```

## Why IngressRoute Uses kubectl_manifest

| Provider | Plan behaviour |
|---|---|
| `hashicorp/kubernetes_manifest` | Queries cluster API during plan → fails on fresh cluster before Traefik CRDs exist. |
| `gavinbunney/kubectl_manifest` | Passes YAML as-is, no CRD lookup at plan time. |

Apply ordering is correct — `depends_on = [module.k8s]` ensures IngressRoutes are created after Traefik is installed.

## Cloudflare Tunnel Wiring

```
Internet → Cloudflare edge
  → DNS CNAME: web.example.com → <tunnel-id>.cfargotunnel.com
  → Tunnel ingress rule: web.example.com → http://web.example-com-prod.svc.cluster.local:80

cloudflared pod (ops namespace, 2 replicas)
  → connects using JWT token from tunnel resource (not the tunnel secret!)
  → proxies requests to in-cluster Service DNS names
```

`CLOUDFLARE_TUNNEL_SECRET` in `.env` is the tunnel creation secret. The JWT token cloudflared uses to connect is derived automatically by Terraform from the tunnel resource.

## Storage Model

Every persistent volume is a `hostPath` rooted at `var.host_volume_path`, which is passed through the project/mysql/component modules as `volume_base_path` without any transformation:

```
Node FS:     {host_volume_path}/{namespace}/{component}/{slug}/
Pod mount:   /{mount-path}
```

The knob is used verbatim — whatever you set, the kubelet sees literally. Which value is correct depends on how the distribution exposes the host FS to the kubelet:

| Distribution | `host_volume_path` example | Notes |
|---|---|---|
| Native k3s on Linux (Option B) | `/data/vol` | k3s runs directly on the host; host path = node path. Browse files with `ls /data/vol/...` from the Linux shell. |
| minikube on Linux, `--driver=none` | `/data/vol` | Same semantics as k3s. |
| minikube on macOS, Docker driver (Option A) | `/minikube-host/Shared/vol` | The minikube VM auto-mounts `/Users` as `/minikube-host`. Files live at `/Users/Shared/vol` on the Mac and the kubelet sees them as `/minikube-host/Shared/vol`. |
| minikube on Linux, `--driver=docker` | path of your own `minikube mount` target | minikube under Linux Docker does not auto-mount the host FS; bind in a directory explicitly and point the variable at it. |

Data survives cluster re-creation because the hostPath lives on the host, not in the ephemeral node layer.

## MySQL Architecture

- Single MySQL 8.0 StatefulSet in `{prefix}platform` namespace
- Per-project DB + user provisioned via `kubernetes_job_v1` (runs mysql client in-cluster)
- DB is NOT dropped on destroy (data preservation)
- Root password: `random_password` → state → `terraform output -json mysql`
- Probes use `sh -c` wrapper (Kubernetes does NOT expand `$(VAR)` in exec probe commands)

## Networking

- **CNI**: Flannel (required on macOS Docker driver)
- **Pod CIDR**: `10.244.0.0/16` (Flannel hardcodes this; changing it breaks Flannel)
- **Service CIDR**: `100.64.0.0/12` (CGNAT range, avoids LAN collisions)
- **Traefik**: Helm chart in `ingress-controller` namespace, NodePort service
- **Cloudflare Tunnel**: replaces LoadBalancer for external access

## Known Limitations

- Single-node only (minikube or a single k3s server). For multi-node k3s, the hostPath model would need to be replaced with a network-backed StorageClass (e.g. longhorn, nfs-subdir).
- Re-bootstrap regenerates MySQL root password but persistent data retains the old one (wipe `{host_volume_path}/{prefix}platform/mysql/` to reset)
- `host_volume_path` is distribution-coupled: the value must match how the kubelet sees the FS (see the Storage Model table above)
