# Platform Architecture

## Repository Layout

```
terraform-minikube-platform/
├── main.tf                  # Module wiring + outputs
├── variables.tf             # Input variables
├── locals.tf                # YAML loading + merging logic
├── cloudflare.tf            # Tunnel resource + ingress rules + DNS records
├── cloudflared.tf           # cloudflared Deployment + Secret in ops namespace
├── _providers.tf            # All provider configs (kubernetes, kubectl, cloudflare)
├── _versions.tf             # Provider version constraints
├── _backend.tf              # Remote state (Backblaze B2 / S3)
├── tf                       # Wrapper script: loads .env, adds bootstrap subcommand
├── config/
│   ├── domains/             # One YAML per project/domain
│   ├── components/          # Reusable component defaults (image, port, replicas)
│   └── limits/default.yaml  # Default namespace ResourceQuota profile
└── modules/
    ├── project/             # Namespace + quota + component orchestration + IngressRoutes
    └── component/           # Deployment + Service only
```

## Assembly Flow

```
locals.tf
  → loads config/domains/*.yaml    → local.projects
  → loads config/components/*.yaml → local.components
  → loads config/limits/default.yaml → local.default_limits

main.tf
  → module.k8s       (terraform-minikube-k8s)
  → module.project   (for_each = local.projects)
  → cloudflare_record, cloudflared resources

modules/project/main.tf
  → merges component_defaults + config/components + per-domain overrides
  → kubernetes_namespace_v1
  → kubernetes_resource_quota_v1
  → module.component  (for each component in project)
  → kubectl_manifest (IngressRoute, for components with ingress_enabled: true)

modules/component/main.tf
  → kubernetes_deployment
  → kubernetes_service
```

## Module Responsibility Split

| Module | Responsibility |
|---|---|
| `modules/component` | `Deployment` + `Service` only. No routing, no namespace concerns. |
| `modules/project` | Namespace, ResourceQuota, component orchestration, IngressRoutes. |
| `cloudflare.tf` | Tunnel resource, per-hostname ingress rules, DNS CNAME records. |
| `cloudflared.tf` | cloudflared Deployment + token Secret in the `ops` namespace. |

## Bootstrap Flow

```
./tf bootstrap
  Step 0:   delete the local minikube profile for cluster_name
              → removes stale ~/.minikube profile metadata before bootstrap

  Step 0.25: delete local terraform.tfstate / backup / lock files
              → forces bootstrap to create from scratch instead of refreshing stale resources from local state

  Step 0.5: delete the stale Cloudflare tunnel named platform
              → prevents tunnel-name collisions on repeated debug bootstraps

  Step 1:   terraform apply -target=module.k8s.minikube_cluster.this
              → Minikube cluster created (Flannel CNI, docker driver)

  Step 1.5: Clean stale CNI interfaces inside the Docker node container
              → docker exec <node> ip link delete cni0
              → docker exec <node> ip link delete flannel.1
              (prevents "cni0 already has an IP different from 10.244.0.1/24"
               on re-bootstrap without full cluster delete)

  Step 2:   terraform apply
              → module.k8s        (Traefik, cert-manager, Prometheus/Grafana, ops StatefulSet)
              → module.project    (namespaces, quotas, Deployments, Services, IngressRoutes)
              → cloudflared       (Deployment + Secret with tunnel token)
              → cloudflare_record (DNS CNAMEs → tunnel CNAME)
```

## Why IngressRoute Lives in `modules/project`

IngressRoutes use `kubectl_manifest` (`gavinbunney/kubectl`) instead of `kubernetes_manifest` (`hashicorp/kubernetes`):

| Provider | Plan behaviour |
|---|---|
| `hashicorp/kubernetes_manifest` | Queries the cluster API during plan to validate the CRD schema. Fails on a fresh cluster before Traefik is installed. |
| `gavinbunney/kubectl_manifest` | Passes YAML through as-is. No CRD lookup at plan time. |

Apply ordering is still correct — `module.project` has `depends_on = [module.k8s]` in `main.tf`, so IngressRoutes are only created after Traefik CRDs are registered.

## Cloudflare Tunnel Wiring

```
Cloudflare edge
  → DNS CNAME: grafana.domain → <tunnel-id>.cfargotunnel.com
  → Tunnel ingress rule: grafana.domain → http://kube-prometheus-stack-grafana.monitoring:80

cloudflared pod (ops namespace, 2 replicas)
  → connects to Cloudflare using JWT token from cloudflare_zero_trust_tunnel_cloudflared.main.tunnel_token
  → proxies inbound requests to in-cluster service DNS names

kubernetes_secret (ops/cloudflared-token)
  → populated by Terraform directly from the tunnel resource output
  → not stored in .env — the JWT is derived from the tunnel resource itself
```

> `.env` contains `CLOUDFLARE_TUNNEL_SECRET` — an arbitrary string used as the tunnel's creation secret in the Cloudflare API. This is different from the JWT token cloudflared uses to connect, which Terraform reads from `cloudflare_zero_trust_tunnel_cloudflared.main.tunnel_token`.

## Networking Notes

- **CNI**: Flannel (required on macOS Docker driver — Calico has pod-to-service routing issues in this setup)
- **service_cidr**: `10.96.0.0/12` — minikube ignores `kubeadm.service-cluster-ip-range` extra_config; kube-apiserver always starts with this range regardless
- **dns_ip**: `10.96.0.10` — must match the real kube-dns ClusterIP; passed from `main.tf` so module defaults don't interfere
- **Traefik**: deployed via Helm to `ingress-controller` namespace, `service.type=NodePort` (no cloud LB needed — Cloudflare Tunnel handles external access)
- **Pod CIDR**: `10.244.0.0/16` (Flannel default)

## Resource Quotas

Each project namespace gets a `ResourceQuota` with limits from `config/limits/default.yaml` (or per-domain override):

```
limits.cpu    = "2"     → namespace-wide CPU limit ceiling
limits.memory = "4Gi"   → namespace-wide memory limit ceiling
```

Component defaults (in `modules/project`):
```
requests.cpu    = 50m
requests.memory = 64Mi
limits.cpu      = 200m
limits.memory   = 256Mi
```

With 3 components × 2 replicas × 200m = 1200m steady-state, well within the 2000m quota. Rolling update adds one extra pod briefly — still fits.

## Known Limitations

- Cloudflare DNS records and tunnel ingress rules are defined statically in `cloudflare.tf` rather than generated from `config/domains/*.yaml`. Adding a new domain requires both a YAML file and a manual entry in `cloudflare.tf`.
- Single-node cluster only in the current default configuration (`nodes = 1`).
