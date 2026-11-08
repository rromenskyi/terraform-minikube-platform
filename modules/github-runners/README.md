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

## Upgrading ARC

Bump `controller_chart_version` and `scale_set_chart_version` together;
the CRDs follow from the controller chart automatically.

The new controller deletes every AutoscalingRunnerSet whose version label
doesn't match its own as soon as it starts, which races an in-place Helm
upgrade of the scale sets: Helm patches the objects while they are being
deleted, reports success, and the runner sets are gone (no listeners, CI
stalls). So the scale-set releases are replaced (`replace_triggered_by`
the controller release's chart version): the apply that bumps the version
uninstalls them first and installs them fresh after the controller
upgrade. Running jobs on those scale sets are cut off, on a patch bump
too. The two chart versions must be equal (a precondition checks it).

If an old-version `AutoscalingListener` is left in the controller
namespace afterwards, delete it; the controller can no longer clean it up
because its runner set no longer exists.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.controller](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.scale_set](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.controller_crds](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.github_pat_vault](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_namespace_v1.controller](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.scale_set](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_secret_v1.github_pat](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.vso_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_controller_chart_version"></a> [controller\_chart\_version](#input\_controller\_chart\_version) | Pinned chart version for `gha-runner-scale-set-controller`. Pin both controller and scale-set chart to the same version — they share a CRD that crosses both releases, and a version skew can break listener-pod creation. | `string` | `"0.15.1"` | no |
| <a name="input_controller_crds"></a> [controller\_crds](#input\_controller\_crds) | CRD manifests of the gha-runner-scale-set-controller chart at the pinned version (e.g. `data.helm_template` with `include_crds = true`, `.crds`), server-side applied by this module. Helm installs a chart's `crds/` once and never upgrades them, so without this the CRDs stay at the version first installed. Rendered by the caller because a data source inside a module with a module-level `depends_on` is deferred to apply whenever that dependency has pending changes, leaving the for\_each keys unknown at plan. | `list(string)` | `[]` | no |
| <a name="input_controller_node_selector"></a> [controller\_node\_selector](#input\_controller\_node\_selector) | Node selector for the controller Deployment. Empty = scheduler picks. Pin to a stable tier (e.g. `{ workload-tier: general }`) so the controller doesn't bounce onto edge nodes. | `map(string)` | `{}` | no |
| <a name="input_controller_tolerations"></a> [controller\_tolerations](#input\_controller\_tolerations) | Tolerations for the controller Deployment. Standard k8s toleration shape. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string, "Exists")<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to install ARC controller + any scale sets. False collapses every resource. | `bool` | `false` | no |
| <a name="input_namespace_controller"></a> [namespace\_controller](#input\_namespace\_controller) | Namespace for the cluster-wide ARC controller. The controller is shared across every scale set; scale-set runner pods land in their own per-set namespaces (see `scale_sets[].namespace`). | `string` | `"arc-system"` | no |
| <a name="input_scale_set_chart_version"></a> [scale\_set\_chart\_version](#input\_scale\_set\_chart\_version) | Pinned chart version for `gha-runner-scale-set`. Match the controller's version (see `controller_chart_version`). | `string` | `"0.15.1"` | no |
| <a name="input_scale_sets"></a> [scale\_sets](#input\_scale\_sets) | Map of runner scale sets to install. Map key is the scale-set name (also the chart release name and the runner label set's identifier). Each entry: `github_config_url` (full URL — `https://github.com/<org>` or `https://github.com/<org>/<repo>` or `https://github.com/enterprises/<ent>`), `vault` (bool, default false — when true, engine emits a `VaultStaticSecret` pointing at `secret/data/platform/github-runner-tokens/<key>`; VSO syncs every key from that Vault path 1:1 into `<key>-github-pat` Secret in the namespace; ARC chart auto-detects PAT vs GitHub-App auth by which keys are present — supply EITHER `github_token` (PAT) OR `github_app_id` + `github_app_installation_id` + `github_app_private_key` (App, preferred for new entries since App handles its own token rotation and avoids the PAT listener-config staleness problem documented in feedback\_arc\_listener\_config\_secret\_stale); preferred path for any new scale set), `github_secret_name` (optional — set to reference an externally-managed k8s Secret carrying GitHub App fields, useful when the Secret is owned by a chart outside this engine; mutually exclusive with `vault: true` and `var.tokens[<key>]`), `namespace` (where the runner pods + listener land — engine creates it), `min_runners` (int, default 0 — scale to zero between jobs is the default; set ≥1 to keep warm runners), `max_runners` (int, default 4 — upper bound on concurrent runners; pick based on cluster headroom), `runner_image` (default pinned to a verified-pullable upstream tag — bump as upstream cuts new releases, and treat it as load-bearing: GitHub hard-deprecates old runner versions, after which the runner still registers but its broker poll returns 403 `Runner version vX is deprecated and cannot receive messages`, the pod exits, and ARC retires the EphemeralRunner as `TooManyPodFailures` after 5 tries — jobs then queue forever with no runner and nothing in the listener logs says why. ARC sets `disableUpdate=true`, so the runner cannot self-update; only this pin moves it. Seen 2026-08-22 with 2.334.0 across every scale set at once), `runner_resources` (k8s resources block), `runner_node_selector` / `runner_tolerations` / `runner_affinity` (placement for runner pods — separate from controller). `runner_affinity` is the standard k8s v1 affinity shape (`nodeAffinity`, `podAffinity`, `podAntiAffinity` keys); empty map preserves chart defaults (no anti-affinity), set `podAntiAffinity` on `kubernetes.io/hostname` to spread N runners across N nodes so a single node loss takes out at most one runner. Empty map = no scale sets, controller still installs (cheap to leave running). | <pre>map(object({<br/>    github_config_url    = string<br/>    vault                = optional(bool, false)<br/>    github_secret_name   = optional(string, "")<br/>    namespace            = string<br/>    min_runners          = optional(number, 0)<br/>    max_runners          = optional(number, 4)<br/>    runner_image         = optional(string, "ghcr.io/actions/actions-runner:2.338.2@sha256:759a1d94a15b05941aba5196974ff43fe15b4cbba29b694b35cbc32a1166b232")<br/>    runner_resources     = optional(any, {})<br/>    runner_node_selector = optional(map(string), {})<br/>    runner_tolerations = optional(list(object({<br/>      key      = optional(string)<br/>      operator = optional(string, "Exists")<br/>      value    = optional(string)<br/>      effect   = optional(string)<br/>    })), [])<br/>    runner_affinity = optional(any, {})<br/>  }))</pre> | `{}` | no |
| <a name="input_tokens"></a> [tokens](#input\_tokens) | LEGACY sensitive map of GitHub PATs keyed by scale-set name. When an entry's key matches a `scale_sets` map key whose `github_secret_name` is empty AND `vault: true` is NOT set, the engine emits a `<key>-github-pat` Secret in the scale-set's namespace carrying `github_token: <value>`. Operator supplies values via `TF_VAR_github_runner_tokens` in `.env`. New entries should prefer `vault: true` on the scale-set entry — values land in Vault under `secret/data/platform/github-runner-tokens/<key>`, no `.env` exposure. This map is left in place for the migration window. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_controller_namespace"></a> [controller\_namespace](#output\_controller\_namespace) | Namespace where the ARC controller is installed. Empty when `enabled = false`. |
| <a name="output_scale_set_names"></a> [scale\_set\_names](#output\_scale\_set\_names) | List of installed scale set names (matches operator-configured map keys). Empty when disabled or no scale sets configured. Retained for backward compatibility — prefer `scale_sets` for new consumers. |
| <a name="output_scale_sets"></a> [scale\_sets](#output\_scale\_sets) | Map of installed scale sets keyed by scale-set name, with non-secret coordinates downstream consumers need to wire workflow files: `runs_on_label` (string — the second element of `runs-on: [self-hosted, <label>]` in the consuming workflow; matches the scale-set name), `github_config_url` (the org / repo / enterprise URL this scale set registers against), `namespace` (k8s namespace the runner pods land in), `min_runners`, `max_runners`. Empty map when disabled. Schema is informational — consumers MAY read via `data.terraform_remote_state` but the platform engine reserves the right to add fields without notice; downstream PRs should not break on additive changes. |
<!-- END_TF_DOCS -->
