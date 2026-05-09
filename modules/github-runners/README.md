# github-runners

GitHub self-hosted runners via ARC (Actions Runner Controller).

Modern path: GitHub-maintained ARC v0.9+ ships two charts —
`gha-runner-scale-set-controller` (one per cluster, watches the
AutoscalingRunnerSet CRD) and `gha-runner-scale-set` (one per
runner pool, registers with a specific org / repo / enterprise
URL via the GitHub Actions API). The controller's listener-pod
pattern replaced the older KEDA-based ARC: it polls GitHub for
queued workflow_jobs and creates / deletes runner pods directly,
scaling 0 → max_runners and back as the queue drains. No KEDA
needed.

Authentication is per-scale-set: either a GitHub App (org-wide,
preferred) or a PAT (token-scoped to a single org / repo / user
context). The engine accepts both via the operator-supplied
Secret name input — engine doesn't store the credential, just
wires the Secret reference into the chart values.

Source-IP / network egress: runners pull from GitHub's HTTPS API
only — no L4 ingress need on the cluster side, no MetalLB
concern. Outbound bandwidth + image-pull caching is the usual
bottleneck on self-hosted; sizing comes from the operator's
observed CI workload.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.scale_set](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace_v1.controller](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.scale_set](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.github_pat](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_controller_chart_version"></a> [controller\_chart\_version](#input\_controller\_chart\_version) | Pinned chart version for `gha-runner-scale-set-controller`. Pin both controller and scale-set chart to the same version — they share a CRD that crosses both releases, and a version skew can break listener-pod creation. | `string` | `"0.9.3"` | no |
| <a name="input_controller_node_selector"></a> [controller\_node\_selector](#input\_controller\_node\_selector) | Node selector for the controller Deployment. Empty = scheduler picks. Pin to a stable tier (e.g. `{ workload-tier: general }`) so the controller doesn't bounce onto edge nodes. | `map(string)` | `{}` | no |
| <a name="input_controller_tolerations"></a> [controller\_tolerations](#input\_controller\_tolerations) | Tolerations for the controller Deployment. Standard k8s toleration shape. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string, "Exists")<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to install ARC controller + any scale sets. False collapses every resource. | `bool` | `false` | no |
| <a name="input_namespace_controller"></a> [namespace\_controller](#input\_namespace\_controller) | Namespace for the cluster-wide ARC controller. The controller is shared across every scale set; scale-set runner pods land in their own per-set namespaces (see `scale_sets[].namespace`). | `string` | `"arc-system"` | no |
| <a name="input_scale_set_chart_version"></a> [scale\_set\_chart\_version](#input\_scale\_set\_chart\_version) | Pinned chart version for `gha-runner-scale-set`. Match the controller's version (see `controller_chart_version`). | `string` | `"0.9.3"` | no |
| <a name="input_scale_sets"></a> [scale\_sets](#input\_scale\_sets) | Map of runner scale sets to install. Map key is the scale-set name (also the chart release name and the runner label set's identifier). Each entry: `github_config_url` (full URL — `https://github.com/<org>` or `https://github.com/<org>/<repo>` or `https://github.com/enterprises/<ent>`), `github_secret_name` (optional — set to reference an externally-managed k8s Secret carrying GitHub App fields; leave empty to have engine emit a `<key>-github-pat` PAT-shaped Secret automatically from `var.tokens[<key>]`), `namespace` (where the runner pods + listener land — engine creates it), `min_runners` (int, default 0 — scale to zero between jobs is the default; set ≥1 to keep warm runners), `max_runners` (int, default 4 — upper bound on concurrent runners; pick based on cluster headroom), `runner_image` (default pinned to a verified-pullable upstream tag — bump as upstream cuts new releases), `runner_resources` (k8s resources block), `runner_node_selector` / `runner_tolerations` / `runner_affinity` (placement for runner pods — separate from controller). `runner_affinity` is the standard k8s v1 affinity shape (`nodeAffinity`, `podAffinity`, `podAntiAffinity` keys); empty map preserves chart defaults (no anti-affinity), set `podAntiAffinity` on `kubernetes.io/hostname` to spread N runners across N nodes so a single node loss takes out at most one runner. Empty map = no scale sets, controller still installs (cheap to leave running). | <pre>map(object({<br/>    github_config_url    = string<br/>    github_secret_name   = optional(string, "")<br/>    namespace            = string<br/>    min_runners          = optional(number, 0)<br/>    max_runners          = optional(number, 4)<br/>    runner_image         = optional(string, "ghcr.io/actions/actions-runner:2.334.0")<br/>    runner_resources     = optional(any, {})<br/>    runner_node_selector = optional(map(string), {})<br/>    runner_tolerations = optional(list(object({<br/>      key      = optional(string)<br/>      operator = optional(string, "Exists")<br/>      value    = optional(string)<br/>      effect   = optional(string)<br/>    })), [])<br/>    runner_affinity = optional(any, {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tokens"></a> [tokens](#input\_tokens) | Sensitive map of GitHub PATs keyed by scale-set name — when an entry's key matches a `scale_sets` map key whose `github_secret_name` is empty, the engine emits a `<key>-github-pat` Secret in the scale-set's namespace carrying `github_token: <value>` and wires the chart to consume it. Operator supplies values via `TF_VAR_github_runner_tokens` (one-time `.env` paste, eventually BWS — see ops backlog). Engine never paths kubectl-create-secret for ARC auth; this map is the only knob. Empty map (default) implies every scale set must reference an externally-managed `github_secret_name`. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_controller_namespace"></a> [controller\_namespace](#output\_controller\_namespace) | Namespace where the ARC controller is installed. Empty when `enabled = false`. |
| <a name="output_scale_set_names"></a> [scale\_set\_names](#output\_scale\_set\_names) | List of installed scale set names (matches operator-configured map keys). Empty when disabled or no scale sets configured. |
<!-- END_TF_DOCS -->
