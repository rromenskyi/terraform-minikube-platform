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
  → derives local.minikube_volume_path from host_volume_path

main.tf
  → module.k8s       (../terraform-minikube-k8s — cluster, Traefik, cert-manager, monitoring)
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

```
Mac host:    /Users/Shared/vol/{namespace}/{component}/{slug}/
Minikube:    /minikube-host/Shared/vol/{namespace}/{component}/{slug}/
Pod mount:   /{mount-path}
```

Data survives cluster re-creation. The `host_volume_path` variable controls the Mac path; the minikube path is derived automatically (`replace("Users", "minikube-host")`).

**Gotcha**: `replace()` with `/pattern/` = regex in Terraform! Use `replace(s, "Users", "minikube-host")` not `replace(s, "/Users/", "/minikube-host/")`.

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

- Single-node only (Minikube)
- Re-bootstrap regenerates MySQL root password but persistent data retains the old one
- macOS-specific hostPath storage (Linux needs different path)
