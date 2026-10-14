# GitHub Actions login — Vault JWT auth that trusts GitHub's OIDC issuer.
#
# A job asks GitHub for an OIDC token (`permissions: id-token: write`) with
# `var.github_actions.audience`, logs in at `auth/<path>/login` with a role
# name, and gets a short-lived Vault token with that role's policy. Nothing
# static is stored in GitHub: what a job may read is decided here, by the
# claims GitHub signs into the token (repository, branch, the workflow file
# and its ref), not by who holds a secret.
#
# Configured through the vault-config-operator CRs like the rest of the
# module, so Terraform itself never talks to Vault.

locals {
  github_actions_instances = var.enabled && var.github_actions != null ? toset(["enabled"]) : toset([])
  github_actions_roles     = var.enabled && var.github_actions != null ? var.github_actions.roles : {}
  github_actions_path      = var.github_actions != null ? var.github_actions.path : "github"
  github_actions_issuer    = "https://token.actions.githubusercontent.com"
}

resource "kubectl_manifest" "github_actions_auth_mount" {
  for_each = local.github_actions_instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "AuthEngineMount"
    metadata = {
      name      = local.github_actions_path
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = "" # mounted at its name
      name           = local.github_actions_path
      type           = "jwt"
      description    = "GitHub Actions OIDC tokens"
    }
  })
}

resource "kubectl_manifest" "github_actions_config" {
  for_each = local.github_actions_instances

  depends_on = [kubectl_manifest.github_actions_auth_mount]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineConfig"
    metadata = {
      name      = local.github_actions_path
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication   = local.vco_authentication
      connection       = local.vco_connection
      path             = local.github_actions_path
      OIDCDiscoveryURL = local.github_actions_issuer
      boundIssuer      = local.github_actions_issuer
    }
  })
}

resource "kubectl_manifest" "github_actions_policy" {
  for_each = local.github_actions_roles

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "github-${each.key}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = each.value.policy
    }
  })
}

resource "kubectl_manifest" "github_actions_role" {
  for_each = local.github_actions_roles

  depends_on = [
    kubectl_manifest.github_actions_config,
    kubectl_manifest.github_actions_policy,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineRole"
    metadata = {
      name      = "github-${each.key}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = local.github_actions_path
      name           = each.key
      roleType       = "jwt"
      boundAudiences = [var.github_actions.audience]
      # Globs, so a role can admit e.g. any pull request ref of one
      # workflow file while another admits only `refs/heads/main`.
      boundClaimsType = "glob"
      boundClaims     = each.value.bound_claims
      # The workflow file and ref identify the job in Vault's audit log.
      userClaim     = "job_workflow_ref"
      tokenPolicies = ["github-${each.key}"]
      tokenTTL      = each.value.token_ttl
      tokenMaxTTL   = each.value.token_max_ttl
    }
  })
}
