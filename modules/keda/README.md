# keda

KEDA — event-driven autoscaling for Deployments and Jobs.

Installs the KEDA operator, its metrics API server (registers the
`external.metrics.k8s.io` APIService the HPA reads) and the admission
webhooks. Tenants ship their own `ScaledObject` / `ScaledJob` resources;
those are namespaced, so a tenant AppProject that only whitelists
namespaced kinds admits them. The engine owns the cluster-scoped CRDs and
the APIService through this chart.

A Deployment scaled by a ScaledObject has its replica count owned by the
HPA that KEDA creates. Whoever else manages that Deployment must not fight
it: Argo CD Applications ignore `/spec/replicas`, Terraform resources use
`ignore_changes = [spec[0].replicas]`.

Tenants whose scaler polls an HTTP endpoint in their namespace (for
example a `metrics-api` trigger) must allow ingress from the KEDA
namespace if they run a NetworkPolicy.

Kubernetes compatibility: KEDA tests each release against three
Kubernetes minors (2.21: v1.34–v1.36). Check the upstream matrix before
bumping `version_pin` or the cluster.

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

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.keda](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace_v1.keda](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module chains its own label off the platform-wide context. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy KEDA. False collapses every resource. | `bool` | `false` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace KEDA lives in. Tenants that let KEDA poll their workloads (for example a `metrics-api` trigger) allow ingress from this namespace by name, so keep it stable. | `string` | `"keda"` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node selector for every KEDA pod (operator, metrics API server, webhooks). Empty map = land wherever k8s schedules. | `map(string)` | `{}` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Tolerations for every KEDA pod, in the k8s toleration shape (`key`, `operator`, `value`, `effect`). | `list(any)` | `[]` | no |
| <a name="input_version_pin"></a> [version\_pin](#input\_version\_pin) | Helm chart version for kedacore/keda (chart and app versions match). Pinned so an upstream release doesn't change CRD shape or defaults across applies. | `string` | `"2.21.0"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace KEDA is installed in. Empty when `enabled = false`. |
<!-- END_TF_DOCS -->
