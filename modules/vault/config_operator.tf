# -----------------------------------------------------------------------------
# Phase 1 — vault-config-operator (RedHat-COP)
#
# Declarative Vault management via CRDs. After the bootstrap Job above gives
# its ServiceAccount admin rights, vco logs into Vault via kubernetes auth
# and reconciles every CRD this module emits below: SecretEngineMount, Policy,
# KubernetesAuthEngineRole, JWTOIDCAuthEngineConfig, JWTOIDCAuthEngineRole.
#
# Repo + docs: https://github.com/redhat-cop/vault-config-operator
#
# Operator namespace is dedicated (`vault-config-operator`) so its RBAC and
# leader-election lock don't tangle with the platform namespace.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "vault_config_operator" {
  for_each = local.instances

  metadata {
    name   = var.vault_config_operator_namespace
    labels = local.tags
  }
}

# CRDs come pre-rendered from the root (`operator_crds.tf`), because
# Helm never upgrades a chart's `crds/`; server-side apply keeps them
# matching the chart version.
resource "kubectl_manifest" "vault_config_operator_crds" {
  for_each = { for doc in var.vault_config_operator_crds : yamldecode(doc).metadata.name => doc }

  yaml_body         = each.value
  server_side_apply = true
  # Keep CRDs when this module is disabled or the resource is removed:
  # deleting a CRD deletes every object of that kind cluster-wide.
  # Retiring them is a deliberate manual step.
  apply_only = true
  # The chart created them client-side on first install; take over the
  # fields it set.
  force_conflicts = true
}

resource "helm_release" "vault_config_operator" {
  for_each = local.instances

  depends_on = [
    kubernetes_namespace_v1.vault_config_operator,
    kubectl_manifest.vault_config_operator_crds,
  ]

  name       = "vault-config-operator"
  repository = "https://redhat-cop.github.io/vault-config-operator"
  chart      = "vault-config-operator"
  # Helm keeps one Secret per revision; each holds the full rendered
  # manifest, so unbounded history slowly fills etcd.
  max_history = 3
  version     = var.vault_config_operator_chart_version
  namespace   = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name

  values = [yamlencode({
    # Default vault address vco uses for all CR reconcile calls.
    vaultAddress = "http://vault.${var.namespace}.svc.cluster.local:8200"

    # NOTE: the chart's `serviceAccount.name` value is IGNORED — the
    # chart hardcodes the SA name to `controller-manager` in its
    # template. Override here removed (was previously setting the value
    # the bootstrap Job's vault role expects, but the override never
    # took effect; bootstrap Job's role binding now references
    # `controller-manager` literally — see variables.tf).

    # Provision serving certs for the operator's webhook + metrics
    # endpoints via cert-manager. Without this the chart leaves
    # `vault-config-operator-certs` and `webhook-server-cert` unfulfilled,
    # the Deployment pod stays `ContainerCreating` on FailedMount, and
    # the Helm release wedges on its Ready wait. The platform already
    # runs cert-manager in `cert-manager` namespace via `module.addons`,
    # so this just lights up the chart's built-in cert-manager
    # Certificate templates.
    enableCertManager = true
  })]

  # Helm Ready-wait — without this the apply returns before the operator
  # is up, and downstream `kubectl_manifest` CRDs land on a chart whose
  # webhook isn't serving yet (admission rejects with "no endpoints").
  wait    = true
  timeout = 300
}

# -----------------------------------------------------------------------------
# Phase 1 — initial CRDs reconciled by vault-config-operator.
#
# Three CRs land:
#   1. KubernetesAuthEngineConfig (no-op if the bootstrap Job already wrote it,
#      but the CR makes the config part of the engine state too — vco will
#      re-assert if Vault drifts).
#   2. SecretEngineMount — KV-v2 at `secret/`.
#   3. Policy `vso-tenant-read` — read on every tenant subtree.
#   4. KubernetesAuthEngineRole `vso` — bind VSO's ServiceAccount to the
#      read-only policy. (VSO Helm release lands in PR-B — the role just sits
#      idle until then, harmless.)
#
# Per-tenant policies + roles + OIDC config live in PR-B (needs Zitadel app).
# -----------------------------------------------------------------------------

locals {
  # Authentication block every CR shares — points at the kubernetes auth
  # method enabled by the bootstrap Job, role `vault-config-operator`. vco
  # picks this up, exchanges its SA JWT for a Vault token via that role,
  # then performs the reconcile call.
  vco_authentication = {
    path = "kubernetes"
    role = "vault-config-operator"
    # Without this, vco impersonates the CRD default SA (`default`), and
    # Vault's k8s-auth role rejects with `service account name not
    # authorized` because it only binds `controller-manager`. Setting
    # this explicitly forces vco to TokenRequest a JWT for the SA the
    # role accepts.
    serviceAccount = {
      name = var.vault_config_operator_service_account
    }
  }

  vco_connection = {
    address = "http://vault.${var.namespace}.svc.cluster.local:8200"
  }
}

resource "kubectl_manifest" "kv_v2_mount" {
  for_each = local.instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "SecretEngineMount"
    metadata = {
      name      = "kv-v2-secret"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = "" # mount AT secret (root of the path is `<name>` from metadata)
      name           = "secret"
      type           = "kv-v2"
    }
  })
}

resource "kubectl_manifest" "vso_read_policy" {
  for_each = local.instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "vso-tenant-read"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      # VSO reads two subtrees of `secret/`:
      #   - `tenants/*`  — per-tenant operator secrets (per-project
      #     `secrets:` blocks, argocd/git deploy keys)
      #   - `platform/*` — cluster-shared operator secrets owned by
      #     the platform layer rather than any tenant (e.g. ARC
      #     GitHub runner tokens at `platform/github-runner-tokens/*`)
      # Tenant-isolation lives at OIDC role policies (Phase 2);
      # VSO's k8s-auth role only ever reads.
      policy = <<-POLICY
        path "secret/data/tenants/*"      { capabilities = ["read"] }
        path "secret/metadata/tenants/*"  { capabilities = ["read", "list"] }
        path "secret/data/platform/*"     { capabilities = ["read"] }
        path "secret/metadata/platform/*" { capabilities = ["read", "list"] }
      POLICY
    }
  })
}

# VSO's kubernetes-auth role binding. References the SA that the upstream
# `hashicorp/vault-secrets-operator` Helm chart creates by default — that
# release lands in PR-B but the role can sit ahead of time, idle until VSO
# pods come up and start using it.
resource "kubectl_manifest" "vso_k8s_role" {
  for_each = local.instances

  depends_on = [
    kubectl_manifest.vso_read_policy,
    kubectl_manifest.kv_v2_mount,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "KubernetesAuthEngineRole"
    metadata = {
      name      = "vso"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = "kubernetes"
      # VSO impersonates this SA in the CONSUMING namespace (the
      # namespace where the VaultStaticSecret CR lives), not in
      # vso's own namespace. This shared role reads every tenant's and
      # the platform's secrets, so it is limited to `vso_shared_namespaces`
      # (platform namespaces such as Argo CD's) when that list is set;
      # tenants authenticate with their own `vso-tenant-<slug>` role.
      # Empty list = every namespace (no tenant isolation).
      targetServiceAccounts = ["vault-secrets-operator-controller-manager"]
      targetNamespaces = merge(
        length(var.vso_shared_namespaces) > 0 ? { targetNamespaces = var.vso_shared_namespaces } : {},
        # `Exists` on the kubelet-set `kubernetes.io/metadata.name` label
        # matches every namespace in the cluster.
        length(var.vso_shared_namespaces) > 0 ? {} : {
          targetNamespaceSelector = {
            matchExpressions = [{ key = "kubernetes.io/metadata.name", operator = "Exists" }]
          }
        },
      )
      policies = ["vso-tenant-read"]
      # KubernetesAuthEngineRole CRD wants seconds-as-int here (different
      # from JWTOIDCAuthEngineRole CRD, which wants a duration string).
      tokenTTL = 86400 # 24h
    }
  })
}

# Identity of the backup Job that takes raft snapshots: read on the
# snapshot endpoint and nothing else, so backups never need the root token.
resource "kubectl_manifest" "snapshot_policy" {
  for_each = var.enabled && var.snapshot_backup != null ? toset(["enabled"]) : toset([])

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "backup-snapshot"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "sys/storage/raft/snapshot" { capabilities = ["read"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "snapshot_role" {
  for_each = var.enabled && var.snapshot_backup != null ? toset(["enabled"]) : toset([])

  depends_on = [kubectl_manifest.snapshot_policy]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "KubernetesAuthEngineRole"
    metadata = {
      name      = "backup-snapshot"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication        = local.vco_authentication
      connection            = local.vco_connection
      path                  = "kubernetes"
      targetServiceAccounts = [var.snapshot_backup.service_account]
      targetNamespaces      = { targetNamespaces = [var.snapshot_backup.namespace] }
      policies              = ["backup-snapshot"]
      tokenTTL              = 900 # 15m — one snapshot
    }
  })
}

# Per-tenant VSO identity: a policy limited to `tenants/<slug>/*` and a
# kubernetes-auth role bound to that tenant's namespaces only. Projects
# reference it through their own VaultAuth, so a VaultStaticSecret in one
# tenant's namespace can't read another tenant's or the platform's paths.
resource "kubectl_manifest" "vso_tenant_policy" {
  for_each = var.enabled ? var.vso_tenants : {}

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "vso-tenant-${each.key}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "secret/data/tenants/${each.key}/*"     { capabilities = ["read"] }
        path "secret/metadata/tenants/${each.key}/*" { capabilities = ["read", "list"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "vso_tenant_role" {
  for_each = var.enabled ? var.vso_tenants : {}

  depends_on = [kubectl_manifest.vso_tenant_policy, kubectl_manifest.kv_v2_mount]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "KubernetesAuthEngineRole"
    metadata = {
      name      = "vso-tenant-${each.key}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication        = local.vco_authentication
      connection            = local.vco_connection
      path                  = "kubernetes"
      targetServiceAccounts = ["vault-secrets-operator-controller-manager"]
      targetNamespaces      = { targetNamespaces = each.value }
      policies              = ["vso-tenant-${each.key}"]
      tokenTTL              = 86400 # 24h
    }
  })
}
