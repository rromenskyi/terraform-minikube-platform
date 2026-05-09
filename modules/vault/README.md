# vault

Vault (Community Edition) StatefulSet with auto-init Job, OIDC mount, and optional VSO operator wiring. Replaces Infisical (whose Phase 1 hit a paywall).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [kubernetes_config_map_v1.vault_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_job_v1.vault_init](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_role_binding_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |
| [kubernetes_secret_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [kubernetes_secret_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/secret_v1) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | n/a | `string` | `"1"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | n/a | `string` | `"100m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy Vault. When false, no resources are created. | `bool` | `false` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Vault answers on (e.g. `vault.example.com`). Used for the IngressRoute Host(...) match (`config/components/vault.yaml` is `kind: external`, the operator's domain yaml supplies the route). | `string` | `""` | no |
| <a name="input_image"></a> [image](#input\_image) | Vault container image. Pin a specific tag — `:latest` would silently pull schema changes between restarts. `hashicorp/vault` is the upstream repo (community edition). | `string` | `"hashicorp/vault:1.18.4"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | n/a | `string` | `"1Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | n/a | `string` | `"256Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace Vault lives in. Expected to exist already (typically `platform`). | `string` | `"platform"` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PV. Vault's raft storage lands at `<volume_base_path>/<namespace>/vault/data/`. Survives `./tf bootstrap-k3s` on purpose — losing this dir wipes the secret store entirely. | `string` | `"/data/vol"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | n/a |
| <a name="output_hostname"></a> [hostname](#output\_hostname) | n/a |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
| <a name="output_port"></a> [port](#output\_port) | n/a |
| <a name="output_root_token"></a> [root\_token](#output\_root\_token) | Root token emitted by `vault operator init`. Use as break-glass when OIDC is broken or before Phase 1 lands. Read with `terraform output -raw vault_root_token`. Empty until the init Job has run + plan picks up the populated Secret on the second apply (k8s data sources are read at plan time). |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | n/a |
| <a name="output_unseal_key"></a> [unseal\_key](#output\_unseal\_key) | Single unseal key (secret\_shares=1, secret\_threshold=1 — single-operator home cluster, no shamir benefit). Used by the StatefulSet's postStart hook to auto-unseal on every pod start. Read with `terraform output -raw vault_unseal_key` if you need to unseal manually for some reason. |
| <a name="output_url"></a> [url](#output\_url) | Public Vault URL — `terraform output -raw vault_url`. |
<!-- END_TF_DOCS -->
