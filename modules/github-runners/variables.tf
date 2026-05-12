variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to install ARC controller + any scale sets. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace_controller" {
  description = "Namespace for the cluster-wide ARC controller. The controller is shared across every scale set; scale-set runner pods land in their own per-set namespaces (see `scale_sets[].namespace`)."
  type        = string
  default     = "arc-system"
}

variable "controller_chart_version" {
  description = "Pinned chart version for `gha-runner-scale-set-controller`. Pin both controller and scale-set chart to the same version — they share a CRD that crosses both releases, and a version skew can break listener-pod creation."
  type        = string
  default     = "0.9.3"
}

variable "scale_set_chart_version" {
  description = "Pinned chart version for `gha-runner-scale-set`. Match the controller's version (see `controller_chart_version`)."
  type        = string
  default     = "0.9.3"
}

variable "controller_node_selector" {
  description = "Node selector for the controller Deployment. Empty = scheduler picks. Pin to a stable tier (e.g. `{ workload-tier: general }`) so the controller doesn't bounce onto edge nodes."
  type        = map(string)
  default     = {}
}

variable "controller_tolerations" {
  description = "Tolerations for the controller Deployment. Standard k8s toleration shape."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "scale_sets" {
  description = "Map of runner scale sets to install. Map key is the scale-set name (also the chart release name and the runner label set's identifier). Each entry: `github_config_url` (full URL — `https://github.com/<org>` or `https://github.com/<org>/<repo>` or `https://github.com/enterprises/<ent>`), `vault` (bool, default false — when true, engine emits a `VaultStaticSecret` pointing at `secret/data/platform/github-runner-tokens/<key>` with one expected data key `github_token`; VSO syncs into `<key>-github-pat` Secret in the namespace; preferred path for new entries), `github_secret_name` (optional — set to reference an externally-managed k8s Secret carrying GitHub App fields; mutually exclusive with `vault: true` and `var.tokens[<key>]`), `namespace` (where the runner pods + listener land — engine creates it), `min_runners` (int, default 0 — scale to zero between jobs is the default; set ≥1 to keep warm runners), `max_runners` (int, default 4 — upper bound on concurrent runners; pick based on cluster headroom), `runner_image` (default pinned to a verified-pullable upstream tag — bump as upstream cuts new releases), `runner_resources` (k8s resources block), `runner_node_selector` / `runner_tolerations` / `runner_affinity` (placement for runner pods — separate from controller). `runner_affinity` is the standard k8s v1 affinity shape (`nodeAffinity`, `podAffinity`, `podAntiAffinity` keys); empty map preserves chart defaults (no anti-affinity), set `podAntiAffinity` on `kubernetes.io/hostname` to spread N runners across N nodes so a single node loss takes out at most one runner. Empty map = no scale sets, controller still installs (cheap to leave running)."
  type = map(object({
    github_config_url    = string
    vault                = optional(bool, false)
    github_secret_name   = optional(string, "")
    namespace            = string
    min_runners          = optional(number, 0)
    max_runners          = optional(number, 4)
    runner_image         = optional(string, "ghcr.io/actions/actions-runner:2.334.0")
    runner_resources     = optional(any, {})
    runner_node_selector = optional(map(string), {})
    runner_tolerations = optional(list(object({
      key      = optional(string)
      operator = optional(string, "Exists")
      value    = optional(string)
      effect   = optional(string)
    })), [])
    runner_affinity = optional(any, {})
  }))
  default = {}
}

variable "tokens" {
  description = "LEGACY sensitive map of GitHub PATs keyed by scale-set name. When an entry's key matches a `scale_sets` map key whose `github_secret_name` is empty AND `vault: true` is NOT set, the engine emits a `<key>-github-pat` Secret in the scale-set's namespace carrying `github_token: <value>`. Operator supplies values via `TF_VAR_github_runner_tokens` in `.env`. New entries should prefer `vault: true` on the scale-set entry — values land in Vault under `secret/data/platform/github-runner-tokens/<key>`, no `.env` exposure. This map is left in place for the migration window."
  type        = map(string)
  default     = {}
  sensitive   = true
}
