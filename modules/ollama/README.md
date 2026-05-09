# ollama

Cluster-internal Ollama (LLM) StatefulSet shared across tenants. Optional GPU offload (Vulkan/Intel Arc supported) configured via the `gpu` variable.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_job_v1.pull_models](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.ollama](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.ollama](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_service_v1.ollama](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.ollama](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_affinity"></a> [affinity](#input\_affinity) | Pod affinity rules for the Ollama pod (node\_affinity /<br/>pod\_affinity / pod\_anti\_affinity). Empty object = no affinity.<br/>Type is `any` because the schema is deeply nested with optional<br/>branches at every level. | `any` | `{}` | no |
| <a name="input_context_length"></a> [context\_length](#input\_context\_length) | Default context window Ollama uses when loading any model.<br/>Ollama's built-in default is 4096 tokens, which silently<br/>truncates prompts that exceed it — observed 2026-04-21 when<br/>the mcp-weather-simple tool catalog (~4500 tokens: 22 tools<br/>× ~150 desc + schemas + instructions preamble) was chopped<br/>from the tail, making later tool schemas invisible to the<br/>model and chat completions returning `tool_calls: []` with<br/>200 OK and no error anywhere. 8192 covers the current<br/>catalog with headroom; qwen2.5 supports 128K natively so<br/>there's lots of room to bump further if new tools push us<br/>past ~6K. One-line tell in Ollama logs when truncation<br/>fires: `truncating input prompt limit=4096 prompt=<N> ...`. | `number` | `8192` | no |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | CPU limit. Inference saturates every core it can get, so keep this generous — the pod lives alone in the `platform` namespace on a single node. | `string` | `"10"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | CPU request. Idle Ollama barely uses any CPU; 200m covers the HTTP server + light background work. | `string` | `"200m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the Ollama StatefulSet + model-pull Job. When `false`, no resources are created and every output collapses to null. | `bool` | `true` | no |
| <a name="input_gpu"></a> [gpu](#input\_gpu) | Optional GPU offload config. `null` (the default) keeps the<br/>StatefulSet on its CPU-only image and unprivileged pod spec.<br/><br/>When set, the StatefulSet swaps in the operator-supplied image,<br/>mounts the operator-supplied host device path, runs the container<br/>privileged with the supplied supplemental groups, and injects the<br/>operator-supplied env vars verbatim. The module bakes in nothing<br/>vendor- or hardware-specific; everything that varies between<br/>Intel/AMD/NVIDIA or between PCI device IDs is supplied here.<br/><br/>`device_type` controls the kubelet hostPath volume type — defaults<br/>to `Directory`, which projects the entire host directory into the<br/>container (right for `/dev/dri` on AMD/Intel, `/dev/nvidia` for<br/>multi-card NVIDIA setups). Set to `CharDevice` to project a single<br/>device file (e.g. `/dev/dri/renderD129`) — useful when the host<br/>has multiple GPUs and you want the container to see only one.<br/><br/>Worked examples:<br/><br/>  # Project all of /dev/dri (Intel/AMD multi-GPU or single-GPU host):<br/>  gpu = {<br/>    image               = "docker.io/ollama/ollama:0.21.1"<br/>    device\_path         = "/dev/dri"<br/>    device\_type         = "Directory"<br/>    supplemental\_groups = [44, 990]<br/>    env = {<br/>      OLLAMA\_VULKAN = "1"<br/>      OLLAMA\_NUM\_GPU = "999"<br/>      ...<br/>    }<br/>  }<br/><br/>  # Project only renderD129 (Arc B50) and hide the iGPU entirely:<br/>  gpu = {<br/>    image               = "docker.io/ollama/ollama:0.21.1"<br/>    device\_path         = "/dev/dri/renderD129"<br/>    device\_type         = "CharDevice"<br/>    supplemental\_groups = [44, 990]<br/>    env = { OLLAMA\_VULKAN = "1", OLLAMA\_NUM\_GPU = "999", ... }<br/>  }<br/><br/>Tenant components are unaffected — they keep their own restricted<br/>securityContexts. | <pre>object({<br/>    image               = string<br/>    device_path         = string<br/>    device_type         = optional(string, "Directory")<br/>    privileged          = optional(bool, true)<br/>    supplemental_groups = list(number)<br/>    env                 = map(string)<br/>  })</pre> | `null` | no |
| <a name="input_keep_alive"></a> [keep\_alive](#input\_keep\_alive) | How long Ollama keeps a model resident in RAM after its last<br/>request. Accepts Go duration strings (`5m`, `24h`) or special<br/>values: `-1` = never unload, `0` = unload immediately.<br/>Ollama's built-in default is `5m` — a model unloads after 5<br/>minutes idle, so the next request pays both the model-load<br/>cost (~3-5 s for qwen3.5:9b) AND a cold prefill of the entire<br/>system prompt + tool catalog (~1.3K tokens in the sibling<br/>mcp-weather-simple's `fat_tools_lean` = ~8-13 s on i7 CPU).<br/>Keeping the model resident lets Ollama's automatic prefix-cache<br/>stay warm across sessions: the first message of any new<br/>conversation skips the catalog prefill. 24h is the sweet spot<br/>for single-operator workloads — hot through the whole day,<br/>quietly drops the model overnight so the kernel can reclaim<br/>the ~6.6 GB that qwen3.5:9b Q4\_K\_M pins. | `string` | `"24h"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | Memory limit. Hitting it kills the pod and evicts every cached model from RAM. 16Gi comfortably fits a 7B–13B model loaded at once. | `string` | `"16Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | Memory request. Inference peaks near the model size — `deepseek-r1:1.5b` fits in 2Gi, 7B models want 6Gi+. | `string` | `"4Gi"` | no |
| <a name="input_models"></a> [models](#input\_models) | Models to pull after the server is ready. The one-shot Job is idempotent — `ollama pull` is a no-op when the model is already cached — so re-applies are cheap. Leave empty to skip the pull step entirely. | `list(string)` | <pre>[<br/>  "deepseek-r1:1.5b"<br/>]</pre> | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the Ollama StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector labels the Ollama pod must match. Empty map means<br/>the scheduler can place the pod on any node. Set this to pin<br/>Ollama on the node that owns the host GPU device referenced in<br/>`var.gpu.device_path` (e.g. `{ gpu = "intel" }` on a multi-node<br/>cluster where one box has the Arc card). Without pinning, the<br/>pod will land on any node and the gpu hostPath will fail<br/>`MountVolume.SetUp failed: not a character device`. | `map(string)` | `{}` | no |
| <a name="input_storage_size"></a> [storage\_size](#input\_storage\_size) | Capacity of the models cache volume. Budget ~2Gi per 1B parameters; a single 7B model is ~4–8Gi, a 70B model is 40Gi+. | `string` | `"50Gi"` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints the Ollama pod tolerates. Each entry is one toleration<br/>block with the standard k8s fields. Empty list = pod cannot<br/>land on any tainted node. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path for the hostPath PersistentVolume. Models cache lands at <volume\_base\_path>/<namespace>/ollama/. | `string` | `"/data/vol"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_host"></a> [host](#output\_host) | Ollama in-cluster hostname, or null if disabled. |
| <a name="output_models"></a> [models](#output\_models) | Models pre-pulled by this module (empty list if disabled). |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace where Ollama is deployed, or null if disabled. |
| <a name="output_port"></a> [port](#output\_port) | Ollama Service port, or null if disabled. |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | Ollama Service name, or null if disabled. |
| <a name="output_url"></a> [url](#output\_url) | Ollama in-cluster URL — drop straight into OLLAMA\_HOST. Null if disabled. |
<!-- END_TF_DOCS -->
