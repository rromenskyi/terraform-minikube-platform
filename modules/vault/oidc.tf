# -----------------------------------------------------------------------------
# Phase 2 — Zitadel OIDC auth method.
#
# Renders three CRs reconciled by vault-config-operator:
#   1. JWTOIDCAuthEngineConfig  → enables `oidc/` auth path, points it
#      at Zitadel's discovery URL, plugs in the client_id/secret from
#      the Vault Application created upstream via module.zitadel-app.
#   2. Policy `operator`        → full sudo on every path. The break-
#      glass equivalent of the root token, gated behind a Zitadel
#      project role grant instead of the Secret-mounted root token.
#   3. JWTOIDCAuthEngineRole `operator` → binds the operator policy to
#      users whose id_token claims include `vault:operator`. Operator
#      assigns this Zitadel project role to themselves once and signs
#      into Vault UI via "Sign in with OIDC".
#
# Per-tenant policies + OIDC roles render in the for_each below.
# -----------------------------------------------------------------------------

locals {
  oidc_instances = (var.enabled && var.oidc_enabled) ? toset(["enabled"]) : toset([])

  # Vault UI's OIDC callback URL. Two callbacks for compatibility with
  # both UI launch paths Vault uses across releases (`/ui/...` for
  # current UI, root `/oidc/callback` for direct API redirects).
  oidc_redirect_uris = [
    "https://${var.hostname}/ui/vault/auth/oidc/oidc/callback",
    "https://${var.hostname}/oidc/callback",
  ]

  # Set of tenant entries to project for_each over — empty when OIDC is
  # off (per-tenant CRs only make sense with OIDC enabled).
  tenant_set = (var.enabled && var.oidc_enabled) ? toset(var.tenants) : toset([])
}

# OIDC client_id + client_secret land in a Secret that vco's
# JWTOIDCAuthEngineConfig CR references by Secret name. Engine emits the
# Secret directly (vco operator namespace) so vco's reconcile loop can
# pull it on demand without a CR-managed secret.
resource "kubernetes_secret_v1" "vault_oidc" {
  for_each = local.oidc_instances

  metadata {
    name      = "vault-oidc-client"
    namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    client_id     = var.oidc_client_id
    client_secret = var.oidc_client_secret
  }
}

resource "kubectl_manifest" "oidc_auth_mount" {
  for_each = local.oidc_instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "AuthEngineMount"
    metadata = {
      name      = "oidc"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = "" # mount AT `oidc` (path of name)
      name           = "oidc"
      type           = "oidc"
    }
  })
}

resource "kubectl_manifest" "oidc_config" {
  for_each = local.oidc_instances

  depends_on = [
    helm_release.vault_config_operator,
    kubernetes_secret_v1.vault_oidc,
    # JWTOIDCAuthEngineConfig writes to /v1/auth/oidc/config — only
    # exists after AuthEngineMount enables `oidc/` first.
    kubectl_manifest.oidc_auth_mount,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineConfig"
    metadata = {
      name      = "oidc"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication   = local.vco_authentication
      connection       = local.vco_connection
      path             = "oidc"
      OIDCDiscoveryURL = var.oidc_issuer_url
      OIDCCredentials = {
        # vco shape: secret holding `client_id` + `client_secret` keys
        # under data; vco resolves at reconcile time.
        secret = {
          name = kubernetes_secret_v1.vault_oidc["enabled"].metadata[0].name
        }
      }
      defaultRole = "operator"
    }
  })
}

resource "kubectl_manifest" "operator_policy" {
  for_each = local.oidc_instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "operator"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "operator_oidc_role" {
  for_each = local.oidc_instances

  depends_on = [
    kubectl_manifest.oidc_config,
    kubectl_manifest.operator_policy,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineRole"
    metadata = {
      name      = "operator"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication      = local.vco_authentication
      connection          = local.vco_connection
      path                = "oidc"
      name                = "operator"
      userClaim           = "sub"
      allowedRedirectURIs = local.oidc_redirect_uris
      groupsClaim         = "urn:zitadel:iam:org:project:roles"
      # CRD field is `tokenPolicies` (not `policies` — that's
      # KubernetesAuthEngineRole's name; vco silently ignores
      # unrecognised fields and the role lands with empty
      # token_policies → login authenticates but binds no policy).
      tokenPolicies   = ["operator"]
      boundClaimsType = "string"
      boundClaims = {
        "urn:zitadel:iam:org:project:roles" = [var.oidc_operator_zitadel_role]
      }
      tokenTTL = "8h" # CRD requires duration string, not seconds int
    }
  })
}

# Per-tenant policy + OIDC role. Engine derives `var.tenants` from the
# upstream project list — every tenant namespace gets a free Vault
# tenant. Policy grants RW on `secret/data/tenants/<name>/*`; the OIDC
# role binds the matching `vault:tenant:<name>` Zitadel project role
# claim to that policy. Operator grants the role to the tenant's
# Zitadel user; tenant signs into Vault UI scoped to their subtree.

resource "kubectl_manifest" "tenant_policy" {
  for_each = local.tenant_set

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "tenant-${each.value}-rw"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "secret/data/tenants/${each.value}/*"     { capabilities = ["create", "read", "update", "delete", "list"] }
        path "secret/metadata/tenants/${each.value}/*" { capabilities = ["read", "list", "delete"] }
        path "secret/data/tenants/${each.value}"       { capabilities = ["list"] }
        path "secret/metadata/tenants/${each.value}"   { capabilities = ["list"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "tenant_oidc_role" {
  for_each = local.tenant_set

  depends_on = [
    kubectl_manifest.oidc_config,
    kubectl_manifest.tenant_policy,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineRole"
    metadata = {
      name      = "tenant-${each.value}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication      = local.vco_authentication
      connection          = local.vco_connection
      path                = "oidc"
      name                = "tenant-${each.value}"
      userClaim           = "sub"
      allowedRedirectURIs = local.oidc_redirect_uris
      groupsClaim         = "urn:zitadel:iam:org:project:roles"
      tokenPolicies       = ["tenant-${each.value}-rw"]
      boundClaimsType     = "string"
      boundClaims = {
        # Zitadel emits role KEYS (not display names) here. Caller
        # declares matching keys `tenant_<slug>` via module.zitadel-app
        # `roles`; slug hyphens normalised to underscores because some
        # downstream OIDC consumers reject hyphens in claim values.
        "urn:zitadel:iam:org:project:roles" = ["tenant_${replace(each.value, "-", "_")}"]
      }
      tokenTTL = "8h" # CRD requires duration string, not seconds int
    }
  })
}
