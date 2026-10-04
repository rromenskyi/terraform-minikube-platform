# -----------------------------------------------------------------------------
# Phase 2 — Vault Secrets Operator (VSO) + cluster-level VaultConnection
# and VaultAuth.
#
# VSO consumes Vault paths via VaultStaticSecret CRs the engine emits in
# tenant namespaces. The cluster-level VaultConnection + VaultAuth here
# tell every VaultStaticSecret in the cluster how to reach Vault and
# which auth backend / role to use; tenant CRs reference these by name.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "vso" {
  for_each = (var.enabled && var.vso_enabled) ? toset(["enabled"]) : toset([])

  metadata {
    name   = var.vso_namespace
    labels = local.tags
  }
}

resource "helm_release" "vso" {
  for_each = (var.enabled && var.vso_enabled) ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_namespace_v1.vso]

  name       = "vault-secrets-operator"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  # Helm keeps one Secret per revision; each holds the full rendered
  # manifest, so unbounded history slowly fills etcd.
  max_history = 3
  version     = var.vso_chart_version
  namespace   = kubernetes_namespace_v1.vso["enabled"].metadata[0].name

  values = [yamlencode({
    # Default cluster-level VaultConnection + VaultAuth — every
    # VaultStaticSecret in the cluster picks these up unless it
    # references named CRs explicitly. Saves emitting a
    # VaultConnection per tenant namespace.
    defaultVaultConnection = {
      enabled = true
      address = "http://vault.${var.namespace}.svc.cluster.local:8200"
    }
    defaultAuthMethod = {
      enabled = true
      # `namespace` here is Vault's enterprise NAMESPACE feature
      # (HCP/Enterprise only) — NOT a k8s namespace selector. On
      # community Vault it must stay unset; the chart renders an
      # unquoted bare `*` as a YAML alias and parsing dies (line 16:
      # "did not find expected alphabetic or numeric character").
      # Cross-namespace consumption of the default VaultAuth is
      # implicit — VaultStaticSecret CRs in any namespace reference
      # `default` by name and the operator resolves it.
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role           = "vso"
        serviceAccount = "vault-secrets-operator-controller-manager"
      }
    }
    controller = {
      kubeRbacProxy = {
        image = {
          repository = split(":", var.vso_kube_rbac_proxy_image)[0]
          tag        = join(":", slice(split(":", var.vso_kube_rbac_proxy_image), 1, length(split(":", var.vso_kube_rbac_proxy_image))))
        }
      }
    }
  })]

  wait    = true
  timeout = 300
}
