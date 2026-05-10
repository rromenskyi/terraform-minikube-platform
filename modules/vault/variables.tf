variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy Vault. When false, no resources are created."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Vault lives in. Expected to exist already (typically `platform`)."
  type        = string
  default     = "platform"
}

variable "hostname" {
  description = "Public hostname Vault answers on (e.g. `vault.example.com`). Used for the IngressRoute Host(...) match (`config/components/vault.yaml` is `kind: external`, the operator's domain yaml supplies the route)."
  type        = string
  default     = ""
}

variable "image" {
  description = "Vault container image. Pin a specific tag — `:latest` would silently pull schema changes between restarts. `hashicorp/vault` is the upstream repo (community edition)."
  type        = string
  default     = "hashicorp/vault:1.18.4"
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PV. Vault's raft storage lands at `<volume_base_path>/<namespace>/vault/data/`. Survives `./tf bootstrap-k3s` on purpose — losing this dir wipes the secret store entirely."
  type        = string
  default     = "/data/vol"
}

variable "memory_request" {
  type    = string
  default = "256Mi"
}

variable "memory_limit" {
  type    = string
  default = "1Gi"
}

variable "cpu_request" {
  type    = string
  default = "100m"
}

variable "cpu_limit" {
  type    = string
  default = "1"
}

# -----------------------------------------------------------------------------
# Phase 1 — bootstrap step that lets vault-config-operator take over.
# The bootstrap Job (post-init, post-unseal) creates the minimum needed for
# vault-config-operator to authenticate and start reconciling its CRDs:
#   - kubernetes auth method enabled + configured
#   - admin policy `vault-config-operator-admin`
#   - kubernetes-auth role binding vco's ServiceAccount → admin policy
# Everything else (KV-v2 mount, VSO read-only policy, OIDC auth method,
# per-tenant policies + OIDC roles) lands as `kubectl_manifest`-managed CRDs
# in subsequent PRs.
# -----------------------------------------------------------------------------

variable "vault_config_operator_namespace" {
  description = "Namespace where vault-config-operator's ServiceAccount lives. The Phase 1 bootstrap Job pre-configures Vault's kubernetes auth method to trust this `<ns>:<sa>` so that vault-config-operator (installed via Helm release in this same module) can authenticate against Vault and reconcile its CRDs."
  type        = string
  default     = "vault-config-operator"
}

variable "vault_config_operator_service_account" {
  description = "ServiceAccount name vault-config-operator authenticates with against Vault's kubernetes auth method. The Phase 1 bootstrap Job binds this SA to the `vault-config-operator-admin` policy via a kubernetes-auth role."
  type        = string
  default     = "vault-config-operator-controller-manager"
}

variable "vault_config_operator_chart_version" {
  description = "Chart version for the vault-config-operator Helm release. Pinned so apply-at-time is deterministic; bump deliberately."
  type        = string
  default     = "0.8.48"
}

# -----------------------------------------------------------------------------
# Phase 2 — OIDC self-serve via Zitadel.
# When OIDC is enabled, vco emits a JWTOIDCAuthEngineConfig pointing at
# Zitadel, plus an admin role bound to the `vault:operator` Zitadel project
# role and (optionally) one role per tenant bound to `vault:tenant:<name>`.
# Operator and tenants log into Vault UI via "Sign in with OIDC" and land
# scoped to their policy — no userpass, no manual token paste.
# -----------------------------------------------------------------------------

variable "oidc_enabled" {
  description = "Enable Zitadel OIDC auth method on Vault. False keeps Vault root-token-only (operator break-glass; tenants cannot self-serve via UI). True needs `oidc_issuer_url`, `oidc_client_id`, `oidc_client_secret` populated — caller wires `module.zitadel-app` upstream and pipes the resulting client_id / client_secret here."
  type        = bool
  default     = false
}

variable "oidc_issuer_url" {
  description = "Zitadel public issuer URL Vault uses for OIDC discovery (`<issuer>/.well-known/openid-configuration`). Same value passed to other OIDC consumers in the platform (oauth2-proxy, stalwart, etc). Required when `oidc_enabled = true`."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "Vault's Zitadel OIDC client_id. Caller creates the Zitadel Application via `module.zitadel-app` and pipes the resulting client_id here. Required when `oidc_enabled = true`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_client_secret" {
  description = "Vault's Zitadel OIDC client_secret. Sensitive. Caller pipes from `module.zitadel-app`. Required when `oidc_enabled = true`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_operator_zitadel_role" {
  description = "Zitadel project role KEY granting full Vault admin access via OIDC. The role's KEY (not its display name) lands in the user's id_token under `urn:zitadel:iam:org:project:roles`; vco's `JWTOIDCAuthEngineRole operator` matches that string and binds users to the `operator` policy (full sudo). Operator's own Zitadel user must hold this project role for SSO to land them on the admin UI. Default `operator` matches the role caller declares via `module.zitadel-app` `roles` input."
  type        = string
  default     = "operator"
}

variable "tenants" {
  description = "Tenants getting their own `secret/data/tenants/<name>/*` Vault path + RW policy + OIDC role. Each entry is a short, DNS-safe name (used in the path, the policy name `tenant-<name>-rw`, and the OIDC role's `bound_claims`). The matching Zitadel project role is `vault:tenant:<name>` — operator grants that role to the relevant Zitadel user(s), they sign into Vault UI via OIDC and land scoped to their tenant subtree. Empty list = no tenant policies emitted (Vault stays operator-only via `oidc_operator_zitadel_role`). Engine derives this from `keys(local.projects)` upstream — every project namespace gets a Vault tenant for free."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for t in var.tenants : can(regex("^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$", t))])
    error_message = "Each tenant name must be 2-40 chars, lowercase alphanumeric with internal hyphens. Used directly in Vault paths and policy names."
  }
}

# -----------------------------------------------------------------------------
# Phase 2 — Vault Secrets Operator (VSO).
# Hashicorp's official VSO consumes Vault paths and materialises them as k8s
# Secrets in tenant namespaces. The engine emits `VaultStaticSecret` CRs
# pointing at `secret/data/tenants/<tenant>/<name>` paths; VSO syncs them
# into the tenant namespace under the same Secret name as in the operator
# config, keeping consumer charts (envFrom, etc) unchanged.
# -----------------------------------------------------------------------------

variable "vso_enabled" {
  description = "Install hashicorp/vault-secrets-operator + cluster-level `VaultConnection` and `VaultAuth`. Required for the engine's `vault_path` mode in `operator_secret_values` to actually materialise k8s Secrets from Vault. Default false keeps the operator absent — engine vault_path entries would emit CRs that nothing reconciles, which is not useful."
  type        = bool
  default     = false
}

variable "vso_chart_version" {
  description = "Chart version for hashicorp/vault-secrets-operator. Pinned so apply-time is deterministic; bump deliberately."
  type        = string
  default     = "0.10.0"
}

variable "vso_namespace" {
  description = "Namespace VSO controller-manager + its k8s ServiceAccount live in. The Phase 1 bootstrap CRDs already configured a kubernetes-auth role for `vault-secrets-operator-controller-manager` in this namespace; changing this default requires also updating the matching CR target."
  type        = string
  default     = "vault-secrets-operator"
}
