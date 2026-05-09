variable "enabled" {
  description = "Deploy the Ollama StatefulSet + model-pull Job. When `false`, no resources are created and every output collapses to null."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the Ollama StatefulSet lives in. Expected to exist already — created by the root-level `platform.tf` alongside every other shared service. Null when `enabled = false`."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path for the hostPath PersistentVolume. Models cache lands at <volume_base_path>/<namespace>/ollama/."
  type        = string
  default     = "/data/vol"
}

variable "storage_size" {
  description = "Capacity of the models cache volume. Budget ~2Gi per 1B parameters; a single 7B model is ~4–8Gi, a 70B model is 40Gi+."
  type        = string
  default     = "50Gi"
}

variable "memory_request" {
  description = "Memory request. Inference peaks near the model size — `deepseek-r1:1.5b` fits in 2Gi, 7B models want 6Gi+."
  type        = string
  default     = "4Gi"
}

variable "memory_limit" {
  description = "Memory limit. Hitting it kills the pod and evicts every cached model from RAM. 16Gi comfortably fits a 7B–13B model loaded at once."
  type        = string
  default     = "16Gi"
}

variable "cpu_request" {
  description = "CPU request. Idle Ollama barely uses any CPU; 200m covers the HTTP server + light background work."
  type        = string
  default     = "200m"
}

variable "cpu_limit" {
  description = "CPU limit. Inference saturates every core it can get, so keep this generous — the pod lives alone in the `platform` namespace on a single node."
  type        = string
  default     = "10"
}

variable "models" {
  description = "Models to pull after the server is ready. The one-shot Job is idempotent — `ollama pull` is a no-op when the model is already cached — so re-applies are cheap. Leave empty to skip the pull step entirely."
  type        = list(string)
  default     = ["deepseek-r1:1.5b"]
}

variable "context_length" {
  description = <<-EOT
    Default context window Ollama uses when loading any model.
    Ollama's built-in default is 4096 tokens, which silently
    truncates prompts that exceed it — observed 2026-04-21 when
    the mcp-weather-simple tool catalog (~4500 tokens: 22 tools
    × ~150 desc + schemas + instructions preamble) was chopped
    from the tail, making later tool schemas invisible to the
    model and chat completions returning `tool_calls: []` with
    200 OK and no error anywhere. 8192 covers the current
    catalog with headroom; qwen2.5 supports 128K natively so
    there's lots of room to bump further if new tools push us
    past ~6K. One-line tell in Ollama logs when truncation
    fires: `truncating input prompt limit=4096 prompt=<N> ...`.
  EOT
  type        = number
  default     = 8192
}

variable "keep_alive" {
  description = <<-EOT
    How long Ollama keeps a model resident in RAM after its last
    request. Accepts Go duration strings (`5m`, `24h`) or special
    values: `-1` = never unload, `0` = unload immediately.
    Ollama's built-in default is `5m` — a model unloads after 5
    minutes idle, so the next request pays both the model-load
    cost (~3-5 s for qwen3.5:9b) AND a cold prefill of the entire
    system prompt + tool catalog (~1.3K tokens in the sibling
    mcp-weather-simple's `fat_tools_lean` = ~8-13 s on i7 CPU).
    Keeping the model resident lets Ollama's automatic prefix-cache
    stay warm across sessions: the first message of any new
    conversation skips the catalog prefill. 24h is the sweet spot
    for single-operator workloads — hot through the whole day,
    quietly drops the model overnight so the kernel can reclaim
    the ~6.6 GB that qwen3.5:9b Q4_K_M pins.
  EOT
  type        = string
  default     = "24h"
}

variable "gpu" {
  description = <<-EOT
    Optional GPU offload config. `null` (the default) keeps the
    StatefulSet on its CPU-only image and unprivileged pod spec.

    When set, the StatefulSet swaps in the operator-supplied image,
    mounts the operator-supplied host device path, runs the container
    privileged with the supplied supplemental groups, and injects the
    operator-supplied env vars verbatim. The module bakes in nothing
    vendor- or hardware-specific; everything that varies between
    Intel/AMD/NVIDIA or between PCI device IDs is supplied here.

    `device_type` controls the kubelet hostPath volume type — defaults
    to `Directory`, which projects the entire host directory into the
    container (right for `/dev/dri` on AMD/Intel, `/dev/nvidia` for
    multi-card NVIDIA setups). Set to `CharDevice` to project a single
    device file (e.g. `/dev/dri/renderD129`) — useful when the host
    has multiple GPUs and you want the container to see only one.

    Worked examples:

      # Project all of /dev/dri (Intel/AMD multi-GPU or single-GPU host):
      gpu = {
        image               = "docker.io/ollama/ollama:0.21.1"
        device_path         = "/dev/dri"
        device_type         = "Directory"
        supplemental_groups = [44, 990]
        env = {
          OLLAMA_VULKAN = "1"
          OLLAMA_NUM_GPU = "999"
          ...
        }
      }

      # Project only renderD129 (Arc B50) and hide the iGPU entirely:
      gpu = {
        image               = "docker.io/ollama/ollama:0.21.1"
        device_path         = "/dev/dri/renderD129"
        device_type         = "CharDevice"
        supplemental_groups = [44, 990]
        env = { OLLAMA_VULKAN = "1", OLLAMA_NUM_GPU = "999", ... }
      }

    Tenant components are unaffected — they keep their own restricted
    securityContexts.
  EOT
  type = object({
    image               = string
    device_path         = string
    device_type         = optional(string, "Directory")
    privileged          = optional(bool, true)
    supplemental_groups = list(number)
    env                 = map(string)
  })
  default = null
  validation {
    # HCL `||` evaluates both operands eagerly; wrap the attribute
    # access in `try()` so the validator passes through when var.gpu
    # is null instead of erroring on the missing attribute.
    condition     = try(contains(["Directory", "CharDevice", "BlockDevice", "File"], var.gpu.device_type), true)
    error_message = "ollama gpu.device_type must be one of: Directory, CharDevice, BlockDevice, File. Mirrors kubelet hostPath types."
  }
}

variable "node_selector" {
  description = <<-EOT
    Node-selector labels the Ollama pod must match. Empty map means
    the scheduler can place the pod on any node. Set this to pin
    Ollama on the node that owns the host GPU device referenced in
    `var.gpu.device_path` (e.g. `{ gpu = "intel" }` on a multi-node
    cluster where one box has the Arc card). Without pinning, the
    pod will land on any node and the gpu hostPath will fail
    `MountVolume.SetUp failed: not a character device`.
  EOT
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = <<-EOT
    Taints the Ollama pod tolerates. Each entry is one toleration
    block with the standard k8s fields. Empty list = pod cannot
    land on any tainted node.
  EOT
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "affinity" {
  description = <<-EOT
    Pod affinity rules for the Ollama pod (node_affinity /
    pod_affinity / pod_anti_affinity). Empty object = no affinity.
    Type is `any` because the schema is deeply nested with optional
    branches at every level.
  EOT
  type        = any
  default     = {}
}
