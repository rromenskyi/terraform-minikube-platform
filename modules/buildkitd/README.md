# buildkitd

Cluster-internal BuildKit daemon for self-hosted runner image builds — single shared Pod with hostPath cache, exposes gRPC on port 1234. Trust model is the CERN userns pattern (`securityContext.privileged: true` inside a Pod with `hostUsers: false`); see `main.tf` header for the full rationale and why `kubectl_manifest` was needed instead of `kubernetes_deployment_v1`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.this](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_service_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | Container `resources.limits.cpu` for the buildkitd Pod. Cap the spike so a runaway build doesn't starve the rest of the node. `4` (cores) suits a typical multi-stage Dockerfile build. | `string` | `"4"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | Container `resources.requests.cpu` for the buildkitd Pod. Buildkit is bursty — the daemon mostly idles between builds and spikes during multi-stage builds. Keep the request low so the Pod isn't blocking scheduler headroom from other workloads. | `string` | `"200m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to install the buildkitd Pod + Service. False collapses every resource to zero — namespace, kubectl\_manifest Deployment, and ClusterIP all disappear, and the `endpoint` output resolves to an empty string. | `bool` | `false` | no |
| <a name="input_host_path"></a> [host\_path](#input\_host\_path) | Cluster-node directory the build cache slabs land in (hostPath volume). Survives Pod restarts but is node-pinned — the daemon should be pinned to the same node via `node_selector` so the cache stays warm. Convention is `<host_volume_path>/buildkit-cache`. | `string` | `"/data/vol/buildkit-cache"` | no |
| <a name="input_image_tag"></a> [image\_tag](#input\_image\_tag) | Tag of the upstream `moby/buildkit` image to run. MUST be the rootful variant — the `-rootless` tags need unprivileged userns creation, which Ubuntu 23.10+ blocks at the AppArmor `userns_create` LSM hook by default. Bump as upstream cuts new releases. | `string` | `"v0.29.0"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | Container `resources.limits.memory` for the buildkitd Pod. Hit OOM during a build → the build fails with a confusing `failed to copy: cancelled` error rather than a clean OOMKilled, so size for the largest expected build. | `string` | `"8Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | Container `resources.requests.memory` for the buildkitd Pod. The daemon's resident set is small (~256Mi) when idle, but in-flight builds blow up the working set during layer pack/unpack. | `string` | `"512Mi"` | no |
| <a name="input_mount_path"></a> [mount\_path](#input\_mount\_path) | In-container path the cache is mounted at. Defaults to the rootful buildkit data directory (`/var/lib/buildkit`). Override only if the operator runs a fork that uses a different layout. | `string` | `"/var/lib/buildkit"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the buildkitd Pod + Service land in. Convention is `arc-buildkitd` (a sibling of the ARC controller's `arc-system` namespace), but operator can override per cluster. Module owns the namespace creation, so the name must not collide with one already managed elsewhere. | `string` | `"arc-buildkitd"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector for the buildkitd Pod. Strongly recommended in any multi-node cluster — the hostPath cache is node-pinned and the daemon needs to land on the same node every time, otherwise a Pod reschedule starts with a cold cache. Empty (default) lets the scheduler pick freely. | `map(string)` | `{}` | no |
| <a name="input_readiness_failure_threshold"></a> [readiness\_failure\_threshold](#input\_readiness\_failure\_threshold) | `readinessProbe.failureThreshold`. One missed probe shouldn't bin a warm cache; `5` gives the daemon room to ride out a transient lock-contention burst. | `number` | `5` | no |
| <a name="input_readiness_initial_delay_seconds"></a> [readiness\_initial\_delay\_seconds](#input\_readiness\_initial\_delay\_seconds) | `readinessProbe.initialDelaySeconds`. buildkitd boots fast (binary, no JVM), so the default of `5` is more than enough. | `number` | `5` | no |
| <a name="input_readiness_period_seconds"></a> [readiness\_period\_seconds](#input\_readiness\_period\_seconds) | `readinessProbe.periodSeconds`. The buildkit-default of `10` killed Pods mid-build under load — `buildctl debug workers` (the probe command) contends with the active build for the OCI worker lock. `60` keeps the probe out of the build's hot path. | `number` | `60` | no |
| <a name="input_readiness_timeout_seconds"></a> [readiness\_timeout\_seconds](#input\_readiness\_timeout\_seconds) | `readinessProbe.timeoutSeconds`. The buildkit-default of `1` is too aggressive when the worker is busy serving a build. `15` is the value that survived a real ARC build cycle on this cluster. | `number` | `15` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations for the buildkitd Pod. Standard k8s toleration shape — set this when the chosen node carries a NoSchedule taint that the buildkitd Pod needs to bypass. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string, "Exists")<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_endpoint"></a> [endpoint](#output\_endpoint) | In-cluster BuildKit gRPC endpoint for `docker buildx create --driver remote --endpoint <this>`. Empty when the module is disabled. |
<!-- END_TF_DOCS -->
