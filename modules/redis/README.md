# redis

Cluster-internal Redis (with optional Sentinel) StatefulSet for tenant components. Per-component Redis user + ACL is provisioned by `modules/project` via a re-runnable Job.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |
| <a name="provider_random"></a> [random](#provider\_random) | 3.8.1 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.valkey_sentinel](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_config_map_v1.haproxy_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.acl_keeper](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_deployment_v1.haproxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_namespace_v1.acl](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_role_binding_v1.acl_keeper_scoped](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.acl_keeper_scoped](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |
| [kubernetes_secret_v1.default](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.acl_keeper](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.redis](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [random_password.default](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_acl_namespace"></a> [acl\_namespace](#input\_acl\_namespace) | Namespace holding the `redis-acl-*` Secrets the ACL keeper applies. Separate from the Redis namespace so the keeper can read these Secrets and nothing else. | `string` | `"redis-acl"` | no |
| <a name="input_affinity"></a> [affinity](#input\_affinity) | Optional pod / node affinity rendered into the Bitnami `valkey` chart's `replica.affinity` block (sentinel mode). Standard Kubernetes affinity shape — `nodeAffinity`, `podAffinity`, `podAntiAffinity` map keys, native v1 schema. Common use: `nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution` excluding a high-latency node from the sentinel pool when the chart's default cluster-wide pod-anti-affinity would otherwise scatter a replica there. Single-instance mode ignores this input. Empty map (default) preserves the chart's default placement. | `any` | `{}` | no |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the Redis StatefulSet. When `false`, no resources are created and every output collapses to null. | `bool` | `true` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | Memory limit for the Redis pod. Hitting this cap kills the pod and takes all tenants down — bump if you expect many large values. | `string` | `"1Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | Memory request for the Redis pod. Redis mmaps its dataset, so this should comfortably cover the working set — anything less than 256Mi is cramped for AOF rewrites. | `string` | `"256Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the Redis StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels the Redis pod must match. Empty = scheduler picks. Set to pin the pod on the node that owns the hostPath data dir (e.g. `{ workload-tier = stateful }`). | `map(string)` | `{}` | no |
| <a name="input_sentinel"></a> [sentinel](#input\_sentinel) | Optional Valkey Sentinel HA topology. When `enabled = true`, the module switches from the default single-StatefulSet implementation to a Bitnami `valkey` Helm release running `architecture: replication` + `sentinel.enabled: true`, plus an HAProxy Deployment in front (sentinel-aware health checks via `tcp-check expect role:master`) so consumers keep talking to the flat `redis.<ns>.svc:6379` Service without any client-side changes. **Operator opts in** via `services.redis.sentinel:` in `config/platform.yaml`. Default `enabled = false` preserves the simple single-instance path. Switching `false → true` is a one-way data wipe (the existing single-instance PVC is destroyed when its for\_each collapses; tenant ACL Jobs need re-trigger to repopulate per-tenant users on the fresh chart deploy). | <pre>object({<br/>    enabled       = optional(bool, false)<br/>    replica_count = optional(number, 3)<br/>    quorum        = optional(number, 2)<br/>    chart_version = optional(string, "5.6.5")<br/>    # `image_tag` and `sentinel_image_tag` default to `latest` because<br/>    # Bitnami / Broadcom moved every versioned `bitnami/<X>:<ver>` tag<br/>    # to the paid Bitnami Secure Images registry in August 2025. The<br/>    # free `docker.io/bitnami/*` images now ship ONLY `:latest` (every<br/>    # prior `:9.x.y` is `404 not found`; the `bitnamilegacy/*` archive<br/>    # does not back-fill). Pinning options short of paying:<br/>    #   1. Digest-pin (`bitnami/valkey@sha256:...`) — what the<br/>    #      `*_digest` defaults below do: `latest` alone let every node<br/>    #      run whichever build it happened to cache. Bump them by hand<br/>    #      from the Docker Hub `latest` tag when upgrading.<br/>    #   2. Switch off the Bitnami chart (run upstream `valkey/valkey`<br/>    #      under our own StatefulSet, or move to the<br/>    #      `valkeyio/valkey-helm-chart` community chart) — real long-<br/>    #      term answer, deferred until a chart switch is on the table.<br/>    # Operator may override here per-deployment if they hit a working<br/>    # tag — but expect 404s on anything other than `latest`.<br/>    image_repo          = optional(string, "bitnami/valkey")<br/>    image_tag           = optional(string, "latest")<br/>    sentinel_image_repo = optional(string, "bitnami/valkey-sentinel")<br/>    sentinel_image_tag  = optional(string, "latest")<br/>    # `latest` as of 2026-11-08 (Valkey 9.1.2, Sentinel 9.1.3). A digest overrides the tag in the chart.<br/>    image_digest          = optional(string, "sha256:3b340a0ca883e7305756cd0ed29fc4a52099343920e022a459a4a0e0cf975ce0")<br/>    sentinel_image_digest = optional(string, "sha256:4fc3aaf5cbd2e85107a440f8edadd11148f021a54a15c8d560484ddfa0d56d20")<br/>    haproxy_image         = optional(string, "haproxytech/haproxy-alpine:3.2")<br/>    haproxy_replicas      = optional(number, 2)<br/>    # Nodes whose Valkey pod may hold a copy and vote in the Sentinel<br/>    # quorum but must never be promoted to primary (`replica-priority 0`),<br/>    # e.g. a WAN-distant node used only as the quorum tie-breaker. HAProxy<br/>    # stays off these nodes too, so clients never take the WAN hop.<br/>    no_primary_nodes = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass name for the Redis PVC. Empty (default) = no `storageClassName` field is set on the PVC, so the cluster's default StorageClass is used (typically `local-path` on k3s, hostPath-backed and node-pinned). Set to a HA-capable SC (e.g. one of `services.longhorn.tag_pools`'s `longhorn-<pool>` outputs) to opt the Redis volume into distributed block storage that survives node failure. The choice is operator-side per `services.redis.storage_class` in `config/platform.yaml` — engine stays generic and does not assume Longhorn or any particular SC implementation is present. | `string` | `""` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints the Redis pod tolerates. Empty list = pod cannot land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PersistentVolume for Redis AOF data. Redis lands at <volume\_base\_path>/<namespace>/redis/. Must resolve to a real writable directory from the kubelet's point of view. | `string` | `"/data/vol"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_acl_namespace"></a> [acl\_namespace](#output\_acl\_namespace) | Namespace for `redis-acl-*` Secrets (label `platform.local/redis-acl=true`, key `setuser`). Empty when the module is disabled. |
| <a name="output_default_password"></a> [default\_password](#output\_default\_password) | Password for the built-in `default` Redis user (aka root). Tenants don't get this — each project module provisions its own ACL user. Null if disabled. |
| <a name="output_default_secret_name"></a> [default\_secret\_name](#output\_default\_secret\_name) | Name of the Secret holding the `default`-user password. The tenant-provisioner Job reads it when calling ACL SETUSER. Null if disabled. |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_helm_revision"></a> [helm\_revision](#output\_helm\_revision) | Helm release revision counter for the Valkey/Sentinel chart. Increments on every `helm upgrade` (chart bump, values change, replicas/affinity update, etc). Consumers (tenant ACL provisioner Jobs) interpolate this into their resource name so a chart upgrade — which can switch the master pod and lose previously-applied ACL state — automatically re-runs the ACL setup with the new credentials. Zero when sentinel mode is disabled (no chart deployed). Sentinel-mode-only by design — the legacy single-pod path uses a different bring-up Job that is not affected by master switches. |
| <a name="output_host"></a> [host](#output\_host) | Redis in-cluster hostname, or null if disabled. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where Redis is deployed, or null if disabled. |
| <a name="output_port"></a> [port](#output\_port) | Redis Service port, or null if disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Redis Service name, or null if disabled. |
<!-- END_TF_DOCS -->
