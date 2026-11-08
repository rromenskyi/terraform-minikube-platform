# vault

Vault (Community Edition) StatefulSet with auto-init Job, OIDC mount, and optional VSO operator wiring. Replaces Infisical (whose Phase 1 hit a paywall).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | github.com/rromenskyi/terraform-null-label | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.vault_config_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.vso](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.kv_v2_mount](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.oidc_auth_mount](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.oidc_config](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.operator_oidc_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.operator_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.snapshot_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.snapshot_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tenant_oidc_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.tenant_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vault_config_operator_crds](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_k8s_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_platform_reader_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_platform_reader_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_read_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_tenant_policy](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.vso_tenant_role](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_cluster_role_binding_v1.vault_token_reviewer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_cluster_role_binding_v1.vco_token_reviewer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/cluster_role_binding_v1) | resource |
| [kubernetes_config_map_v1.vault_config](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/config_map_v1) | resource |
| [kubernetes_job_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_job_v1.vault_init](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/job_v1) | resource |
| [kubernetes_namespace_v1.vault_config_operator](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_namespace_v1.vso](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_role_binding_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_binding_v1) | resource |
| [kubernetes_role_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/role_v1) | resource |
| [kubernetes_secret_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.vault_oidc](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.vault_token_reviewer](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_account_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_stateful_set_v1.vault](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/stateful_set_v1) | resource |
| [kubernetes_secret_v1.vault_bootstrap](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/secret_v1) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | n/a | `string` | `"1"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | n/a | `string` | `"100m"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy Vault. When false, no resources are created. | `bool` | `false` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Vault answers on (e.g. `vault.example.com`). Used for the IngressRoute Host(...) match (`config/components/vault.yaml` is `kind: external`, the operator's domain yaml supplies the route). | `string` | `""` | no |
| <a name="input_image"></a> [image](#input\_image) | Vault container image. Pin a specific tag — `:latest` would silently pull schema changes between restarts. `hashicorp/vault` is the upstream repo (community edition). | `string` | `"hashicorp/vault:2.2.1"` | no |
| <a name="input_init_image"></a> [init\_image](#input\_init\_image) | Image for the one-shot vault-init Job (needs sh, curl, sed, base64, kubectl). Bitnami ships only `:latest`, so pin the digest. | `string` | `"bitnami/kubectl:latest@sha256:8f59408f9e896fc8992a0660a56687545bd06751f26531b4a26fca6d5dc7562d"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | n/a | `string` | `"1Gi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | n/a | `string` | `"256Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace Vault lives in. Expected to exist already (typically `platform`). | `string` | `"platform"` | no |
| <a name="input_oidc_client_id"></a> [oidc\_client\_id](#input\_oidc\_client\_id) | Vault's Zitadel OIDC client\_id. Caller creates the Zitadel Application via `module.zitadel-app` and pipes the resulting client\_id here. Required when `oidc_enabled = true`. | `string` | `""` | no |
| <a name="input_oidc_client_secret"></a> [oidc\_client\_secret](#input\_oidc\_client\_secret) | Vault's Zitadel OIDC client\_secret. Sensitive. Caller pipes from `module.zitadel-app`. Required when `oidc_enabled = true`. | `string` | `""` | no |
| <a name="input_oidc_enabled"></a> [oidc\_enabled](#input\_oidc\_enabled) | Enable Zitadel OIDC auth method on Vault. False keeps Vault root-token-only (operator break-glass; tenants cannot self-serve via UI). True needs `oidc_issuer_url`, `oidc_client_id`, `oidc_client_secret` populated — caller wires `module.zitadel-app` upstream and pipes the resulting client\_id / client\_secret here. | `bool` | `false` | no |
| <a name="input_oidc_issuer_url"></a> [oidc\_issuer\_url](#input\_oidc\_issuer\_url) | Zitadel public issuer URL Vault uses for OIDC discovery (`<issuer>/.well-known/openid-configuration`). Same value passed to other OIDC consumers in the platform (oauth2-proxy, stalwart, etc). Required when `oidc_enabled = true`. | `string` | `""` | no |
| <a name="input_oidc_operator_zitadel_role"></a> [oidc\_operator\_zitadel\_role](#input\_oidc\_operator\_zitadel\_role) | Zitadel project role KEY granting full Vault admin access via OIDC. The role's KEY (not its display name) lands in the user's id\_token under `urn:zitadel:iam:org:project:roles`; vco's `JWTOIDCAuthEngineRole operator` matches that string and binds users to the `operator` policy (full sudo). Operator's own Zitadel user must hold this project role for SSO to land them on the admin UI. Default `operator` matches the role caller declares via `module.zitadel-app` `roles` input. | `string` | `"operator"` | no |
| <a name="input_snapshot_backup"></a> [snapshot\_backup](#input\_snapshot\_backup) | ServiceAccount (`namespace`, `service_account`) of the backup Job that takes raft snapshots. Gets kubernetes-auth role `backup-snapshot` with read on `sys/storage/raft/snapshot` only. Null = no role. | <pre>object({<br/>    namespace       = string<br/>    service_account = string<br/>  })</pre> | `null` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass for Vault's raft data PVC. Empty / `"standard"` (default) uses the static `hostPath` PV the module declares — node-local, survives pod restart but not node loss; pinned to whichever node first attached. Set to `"longhorn"` (or any other dynamic-provisioning SC the cluster has) to drop the hostPath PV and let the cluster provision a network-backed volume — Vault then survives node loss + reschedules cleanly. **Switching is destructive** — the new PVC binds an EMPTY volume; existing raft data on the old hostPath stays on disk but is no longer referenced. Take a `vault operator raft snapshot save` before flipping, then restore after init Job re-runs. | `string` | `""` | no |
| <a name="input_tenants"></a> [tenants](#input\_tenants) | Tenants getting their own `secret/data/tenants/<name>/*` Vault path + RW policy + OIDC role. Each entry is a short, DNS-safe name (used in the path, the policy name `tenant-<name>-rw`, and the OIDC role's `bound_claims`). The matching Zitadel project role is `vault:tenant:<name>` — operator grants that role to the relevant Zitadel user(s), they sign into Vault UI via OIDC and land scoped to their tenant subtree. Empty list = no tenant policies emitted (Vault stays operator-only via `oidc_operator_zitadel_role`). Engine derives this from `keys(local.projects)` upstream — every project namespace gets a Vault tenant for free. | `list(string)` | `[]` | no |
| <a name="input_vault_config_operator_chart_version"></a> [vault\_config\_operator\_chart\_version](#input\_vault\_config\_operator\_chart\_version) | Chart version for the vault-config-operator Helm release. Pinned so apply-at-time is deterministic; bump deliberately. | `string` | `"v1.0.6"` | no |
| <a name="input_vault_config_operator_crds"></a> [vault\_config\_operator\_crds](#input\_vault\_config\_operator\_crds) | CRD manifests of the vault-config-operator chart at the pinned version (e.g. `data.helm_template` with `include_crds = true`, `.crds`), server-side applied by this module. Helm installs a chart's `crds/` once and never upgrades them, so without this the CRDs stay at the version first installed. Rendered by the caller because a data source inside a module with a module-level `depends_on` is deferred to apply whenever that dependency has pending changes, leaving the for\_each keys unknown at plan. | `list(string)` | `[]` | no |
| <a name="input_vault_config_operator_namespace"></a> [vault\_config\_operator\_namespace](#input\_vault\_config\_operator\_namespace) | Namespace where vault-config-operator's ServiceAccount lives. The Phase 1 bootstrap Job pre-configures Vault's kubernetes auth method to trust this `<ns>:<sa>` so that vault-config-operator (installed via Helm release in this same module) can authenticate against Vault and reconcile its CRDs. | `string` | `"vault-config-operator"` | no |
| <a name="input_vault_config_operator_service_account"></a> [vault\_config\_operator\_service\_account](#input\_vault\_config\_operator\_service\_account) | ServiceAccount name vault-config-operator authenticates with against Vault's kubernetes auth method. The Phase 1 bootstrap Job binds this SA to the `vault-config-operator-admin` policy via a kubernetes-auth role. Default `controller-manager` matches the chart's actual SA name (the chart names its SA literally `controller-manager` regardless of `serviceAccount.name` override) — using a different value here would silently break vco's auth and every CR would fail with `service account name not authorized`. | `string` | `"controller-manager"` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PV. Vault's raft storage lands at `<volume_base_path>/<namespace>/vault/data/`. Survives `./tf bootstrap-k3s` on purpose — losing this dir wipes the secret store entirely. Ignored when `storage_class` is set to anything other than `""` / `"standard"` (dynamic provisioning takes over). | `string` | `"/data/vol"` | no |
| <a name="input_vso_chart_version"></a> [vso\_chart\_version](#input\_vso\_chart\_version) | Chart version for hashicorp/vault-secrets-operator. Pinned so apply-time is deterministic; bump deliberately. | `string` | `"1.6.2"` | no |
| <a name="input_vso_enabled"></a> [vso\_enabled](#input\_vso\_enabled) | Install hashicorp/vault-secrets-operator + cluster-level `VaultConnection` and `VaultAuth`. Required for the engine's `vault_path` mode in `operator_secret_values` to actually materialise k8s Secrets from Vault. Default false keeps the operator absent — engine vault\_path entries would emit CRs that nothing reconciles, which is not useful. | `bool` | `false` | no |
| <a name="input_vso_kube_rbac_proxy_image"></a> [vso\_kube\_rbac\_proxy\_image](#input\_vso\_kube\_rbac\_proxy\_image) | kube-rbac-proxy image for the VSO controller's metrics endpoint (`repo:tag`, `@sha256:` digest allowed). The chart's default (v0.18.1) carries critical Go stdlib / grpc CVEs. | `string` | `"quay.io/brancz/kube-rbac-proxy:v0.23.1@sha256:c280684dd23793fb2f287d1f4efc84b7800b3e01205d770b98694827bfe514cb"` | no |
| <a name="input_vso_namespace"></a> [vso\_namespace](#input\_vso\_namespace) | Namespace VSO controller-manager + its k8s ServiceAccount live in. The Phase 1 bootstrap CRDs already configured a kubernetes-auth role for `vault-secrets-operator-controller-manager` in this namespace; changing this default requires also updating the matching CR target. | `string` | `"vault-secrets-operator"` | no |
| <a name="input_vso_platform_readers"></a> [vso\_platform\_readers](#input\_vso\_platform\_readers) | Name => { namespaces, paths }: a VSO identity that reads only the listed secrets (KV paths under the `secret` mount, each starting with `platform/`, exact, no wildcards), for platform services that need one or two secrets and not the shared role's everything. Each entry gets a policy and a kubernetes-auth role `vso-platform-<name>` bound to those namespaces; the service references the role through its own VaultAuth. | <pre>map(object({<br/>    namespaces = list(string)<br/>    paths      = list(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_vso_shared_namespaces"></a> [vso\_shared\_namespaces](#input\_vso\_shared\_namespaces) | Namespaces allowed to use the shared `vso` role, which reads every tenant's and the platform's secrets (e.g. Argo CD for repository credentials, the runner namespace for its tokens). Empty = every namespace, i.e. no tenant isolation. | `list(string)` | `[]` | no |
| <a name="input_vso_tenants"></a> [vso\_tenants](#input\_vso\_tenants) | Tenant slug → namespaces. Each tenant gets a VSO policy limited to `secret/tenants/<slug>/*` and a kubernetes-auth role `vso-tenant-<slug>` bound to those namespaces; projects use it through their own VaultAuth. | `map(list(string))` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | Whether the module deployed Vault. |
| <a name="output_hostname"></a> [hostname](#output\_hostname) | Public Vault hostname; null when disabled or not exposed. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace of the Vault Service; null when disabled. |
| <a name="output_port"></a> [port](#output\_port) | Vault API port on the Service; null when disabled. |
| <a name="output_root_token"></a> [root\_token](#output\_root\_token) | Root token emitted by `vault operator init`. Use as break-glass when OIDC is broken or before Phase 1 lands. Read with `terraform output -raw vault_root_token`. Empty until the init Job has run + plan picks up the populated Secret on the second apply (k8s data sources are read at plan time). |
| <a name="output_service_name"></a> [service\_name](#output\_service\_name) | In-cluster Vault Service name; null when disabled. |
| <a name="output_unseal_key"></a> [unseal\_key](#output\_unseal\_key) | Single unseal key (secret\_shares=1, secret\_threshold=1 — single-operator home cluster, no shamir benefit). Used by the StatefulSet's postStart hook to auto-unseal on every pod start. Read with `terraform output -raw vault_unseal_key` if you need to unseal manually for some reason. |
| <a name="output_url"></a> [url](#output\_url) | Public Vault URL — `terraform output -raw vault_url`. |
<!-- END_TF_DOCS -->
