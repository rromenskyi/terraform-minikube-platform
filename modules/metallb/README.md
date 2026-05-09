# metallb

MetalLB — bare-metal LoadBalancer for k8s on a self-hosted /
VPS cluster. Enables `Service type: LoadBalancer` to allocate
real on-network IPs (instead of the cloud-controller no-op
that leaves them stuck in <pending>).

L2 mode only — no BGP. One node per VIP announces via
gratuitous ARP. Source-IP preservation requires the consuming
Service to set `externalTrafficPolicy: Local` AND the backend
pod to land on the announcing node (kube-proxy does not
forward traffic across nodes when Local is set; it drops if
no local backend exists). Multi-replica horizontal scale on
L2 = DaemonSet pattern (pod on every node that has a speaker)
or multiple Services with distinct VIPs. True multi-active
fronting one VIP needs BGP mode + an upstream router that
speaks BGP — out of scope for this module.

The chart's controller picks IPs from configured pools; speaker
DaemonSet does the L2 announcement. Pools and L2Advertisements
are CRDs the operator config defines per intent.

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

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.metallb](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.ip_pool](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.l2_advertisement](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_annotations.shared_ip](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/annotations) | resource |
| [kubernetes_namespace_v1.metallb](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_controller_node_selector"></a> [controller\_node\_selector](#input\_controller\_node\_selector) | Node selector for the MetalLB controller Deployment. Controller is stateless and picks IPs from pools — it can run anywhere with cluster API access. Empty map = land wherever k8s schedules. Set to a stable tier (e.g. `{ workload-tier: general }`) to avoid the controller bouncing onto edge / tainted nodes. | `map(string)` | `{}` | no |
| <a name="input_controller_tolerations"></a> [controller\_tolerations](#input\_controller\_tolerations) | Tolerations for the MetalLB controller. Standard k8s toleration shape. Empty = controller lands only on un-tainted nodes. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string, "Exists")<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy MetalLB. False collapses every resource. | `bool` | `false` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace MetalLB lives in. Convention is `metallb-system`; the chart's controller and speaker reference each other via in-namespace Services and the CRD validating webhook is namespace-bound, so override only if a fleet-wide policy requires a different one. | `string` | `"metallb-system"` | no |
| <a name="input_pools"></a> [pools](#input\_pools) | IP address pools MetalLB allocates from. Each entry produces one `IPAddressPool` CRD plus, when `l2_node_selectors` is non-empty, one `L2Advertisement` CRD restricting which nodes announce the pool's IPs via ARP (avoids split-brain ARP from multiple speakers offering the same VIP). Map key is the pool name (also used as CRD object name). `addresses` is a list of CIDRs or `start-end` ranges in MetalLB's native syntax. `auto_assign` controls whether unallocated IPs in the pool can be auto-picked for `Service type: LoadBalancer` without an explicit `loadBalancerIP` request — set false for tightly-controlled pools where every Service must opt in by name. `l2_node_selectors` is a list of label-selector maps that becomes the `L2Advertisement.spec.nodeSelectors` field; restricts which nodes announce these IPs (defaults to all nodes with a speaker if empty). Empty `pools` map = MetalLB installed but inert. | <pre>map(object({<br/>    addresses         = list(string)<br/>    auto_assign       = optional(bool, true)<br/>    l2_node_selectors = optional(list(map(string)), [])<br/>  }))</pre> | `{}` | no |
| <a name="input_shared_ip_annotations"></a> [shared\_ip\_annotations](#input\_shared\_ip\_annotations) | Map of `<namespace>/<service-name>` → shared-ip key. Engine annotates the listed Service with `metallb.io/allow-shared-ip: <key>` so MetalLB legalises sharing one VIP across multiple Services with non-conflicting port/protocol pairs (e.g. Traefik on TCP 80/443 and a SIP proxy on UDP 5160). Both Services must carry the SAME key AND the same `externalTrafficPolicy` (MetalLB rejects sharing across mismatched policies); the engine writes the annotation server-side without touching the Service's other fields, so a chart-managed Service (Helm, ArgoCD) keeps its ownership intact. Empty map (default) emits no annotations. Only meaningful when at least one pool's IP is targeted by multiple Services. | `map(string)` | `{}` | no |
| <a name="input_speaker_node_selector"></a> [speaker\_node\_selector](#input\_speaker\_node\_selector) | Node selector for the speaker DaemonSet. The speaker MUST land on the node(s) that should announce VIPs via L2 ARP — the IP physically arrives on that node's NIC. Restricting via nodeSelector keeps speaker pods off nodes that have no business announcing (e.g. home nodes that aren't on the public network). Empty map = speaker DaemonSet lands on every (un-tainted) node, which is the chart default but rarely what you want for a multi-tier cluster. | `map(string)` | `{}` | no |
| <a name="input_speaker_tolerations"></a> [speaker\_tolerations](#input\_speaker\_tolerations) | Tolerations for the speaker DaemonSet. If the announcing node is tainted (e.g. dedicated-app taint on a VPS that also serves as the LB ingress node), the speaker must tolerate the taint to land there. Standard k8s toleration shape. Empty = speaker lands only on un-tainted nodes. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string, "Exists")<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_version_pin"></a> [version\_pin](#input\_version\_pin) | Helm chart version for metallb/metallb. Pinned so an upstream re-tag doesn't change CRD shape or defaults across applies. | `string` | `"0.15.3"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace MetalLB is installed in. Empty when `enabled = false`. |
| <a name="output_pools"></a> [pools](#output\_pools) | Map of pool name → addresses, mirroring the input. Useful for downstream modules that want to assert a pool exists before requesting `loadBalancerIP` from it. |
<!-- END_TF_DOCS -->
