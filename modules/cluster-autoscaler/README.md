# cluster-autoscaler

Upstream [cluster-autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
for power-managed bare-metal node pools: the `externalgrpc` cloud provider
is served by [plugpool](https://github.com/ipsupport-llc/plugpool), a
sidecar in the same pod, which powers machines on and off through their
ESPHome smart plugs. Each node group behaves like a cloud node pool with a
minimum of zero: a pending pod that fits the group's template powers a
machine on; a machine unneeded for `scale_down_unneeded_time` is drained,
shut down and switched off, and its Node is deleted.

plugpool's safety rules apply (only configured plugs; a registered node
that cluster-autoscaler has not marked for deletion is never shut down or
switched off); see its README.

- The pod must run off every power-managed machine and on a node that can
  reach the plugs (`node_selector`).
- The plugs' web password comes from Vault (`vault_path`, key `password`)
  through the Vault Secrets Operator; give `vault_auth_role` for a role
  limited to that path.
- The namespace is Pod Security `privileged` (the poweroff pods); do not
  put a ResourceQuota on it.
- Disabling the module leaves the machines as they are: a machine that is
  off stays off until it is switched on by hand.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | 1.19.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.38.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.plug_secret](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.service_monitor](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vault_auth](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_cluster_role_binding_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_v1) | resource |
| [kubernetes_config_map_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_deployment_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_role_binding_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |
| [kubernetes_service_account_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_account_v1.vso_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.metrics](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ca_image"></a> [ca\_image](#input\_ca\_image) | cluster-autoscaler image (externalgrpc cloud provider). | `string` | `"registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.1@sha256:461388d03eb5b55db58941ee7a81d9a619dd15302b01cbab9f5a9946715994b4"` | no |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label` (root passes `module.platform_label.context`). Null = a label with no inherited context. | `string` | `null` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to run cluster-autoscaler with the plugpool sidecar. False creates nothing. Turning it off later leaves the machines as they are: one that is powered off stays off until it is switched on by hand. | `bool` | `false` | no |
| <a name="input_max_node_provision_time"></a> [max\_node\_provision\_time](#input\_max\_node\_provision\_time) | cluster-autoscaler `--max-node-provision-time`: a machine that has not registered this long after its power-on counts as failed; its plug is switched off again. | `string` | `"10m"` | no |
| <a name="input_monitoring"></a> [monitoring](#input\_monitoring) | Scrape cluster-autoscaler's metrics (Service + ServiceMonitor on port 8085). Needs the Prometheus operator CRDs. | `bool` | `true` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace of cluster-autoscaler, plugpool and the one-shot poweroff pods. The module owns it and labels it Pod Security `privileged` (the poweroff pods run privileged with host PID). Do not put a ResourceQuota on it: the poweroff pods use priority class `system-node-critical`. | `string` | `"cluster-autoscaler"` | no |
| <a name="input_node_groups"></a> [node\_groups](#input\_node\_groups) | Power-managed node groups, one cluster-autoscaler node group each:<br/>  - id, min\_size, max\_size (at most the number of nodes)<br/>  - template: what a new machine of the group offers, for scale-up from<br/>    zero (cpu, memory, pods, labels — include the label workloads select<br/>    the group by — and taints). Do not claim more than the machine's<br/>    allocatable: cluster-autoscaler would power machines on for pods<br/>    that do not fit.<br/>  - nodes: the Kubernetes node name of each machine, its plug's ESPHome<br/>    web server URL and the switch entity driving the relay. One plug per<br/>    machine. | <pre>list(object({<br/>    id       = string<br/>    min_size = number<br/>    max_size = number<br/>    template = object({<br/>      cpu    = string<br/>      memory = string<br/>      pods   = optional(string, "110")<br/>      labels = optional(map(string), {})<br/>      taints = optional(list(object({<br/>        key    = string<br/>        value  = optional(string)<br/>        effect = string<br/>      })), [])<br/>    })<br/>    nodes = list(object({<br/>      name        = string<br/>      plug_url    = string<br/>      plug_switch = string<br/>    }))<br/>  }))</pre> | `[]` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector of the autoscaler pod. It must keep the pod off every power-managed machine and on a node that can reach the plugs. | `map(string)` | `{}` | no |
| <a name="input_plug_username"></a> [plug\_username](#input\_plug\_username) | HTTP basic-auth user of the plugs' web servers. | `string` | `"admin"` | no |
| <a name="input_plugpool_image"></a> [plugpool\_image](#input\_plugpool\_image) | plugpool image: the externalgrpc provider that powers machines through ESPHome smart plugs (github.com/ipsupport-llc/plugpool). | `string` | `"ghcr.io/ipsupport-llc/plugpool:0.1.0@sha256:cab8356b58c7d2aff7dc7827caaeddd4c45fa8be15e646bbc2feaa2835bcf151"` | no |
| <a name="input_poweroff_image"></a> [poweroff\_image](#input\_poweroff\_image) | Image of the one-shot poweroff pod; it must provide `nsenter`. | `string` | `"busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"` | no |
| <a name="input_prometheus_selector_labels"></a> [prometheus\_selector\_labels](#input\_prometheus\_selector\_labels) | Labels the cluster's Prometheus selects ServiceMonitors by. | `map(string)` | <pre>{<br/>  "release": "kube-prometheus-stack"<br/>}</pre> | no |
| <a name="input_provider_id_prefix"></a> [provider\_id\_prefix](#input\_provider\_id\_prefix) | Node `spec.providerID` = prefix + node name (k3s: `k3s://`). plugpool matches nodes to machines by it. | `string` | `"k3s://"` | no |
| <a name="input_scale_down_delay_after_add"></a> [scale\_down\_delay\_after\_add](#input\_scale\_down\_delay\_after\_add) | cluster-autoscaler `--scale-down-delay-after-add`: no scale-down this long after a power-on. | `string` | `"30m"` | no |
| <a name="input_scale_down_unneeded_time"></a> [scale\_down\_unneeded\_time](#input\_scale\_down\_unneeded\_time) | cluster-autoscaler `--scale-down-unneeded-time`: how long a machine must be unneeded before it is powered off. | `string` | `"30m"` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations of the autoscaler pod. | <pre>list(object({<br/>    key      = optional(string)<br/>    operator = optional(string, "Exists")<br/>    value    = optional(string)<br/>    effect   = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_vault_auth_role"></a> [vault\_auth\_role](#input\_vault\_auth\_role) | Vault kubernetes-auth role the sync authenticates with, through a VaultAuth in the namespace (a role limited to `vault_path`). Empty = VSO's cluster-default VaultAuth, whose role must then bind this namespace. | `string` | `""` | no |
| <a name="input_vault_path"></a> [vault\_path](#input\_vault\_path) | Vault KV v2 path (mount `secret`) holding the plugs' web password under key `password`; synced by the Vault Secrets Operator into Secret `plugpool-plugs`. Required when enabled. | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace of cluster-autoscaler, plugpool and the poweroff pods; empty when disabled. |
<!-- END_TF_DOCS -->
