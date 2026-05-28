# Argo CD repo credential Secrets.
#
# Per-tenant model: each `argocd_bootstraps:` entry lives under a project
# in the domain yaml; that project's `slug` (e.g. `example-com`) is the
# tenant the deploy credential is owned by.
#
# Three emit modes per (url, cred-id) pair, picked by which field the
# `argocd_bootstraps:` entry sets:
#
#   1. **SSH key, Vault** (default — entry has `repo_ssh_key_id: <id>`,
#      operator did NOT add `<id>` to `var.argocd_repo_ssh_keys`).
#      Engine emits a `VaultStaticSecret` CR pointing at
#      `secret/data/tenants/<slug>/argocd-deploy-keys/<id>` with one
#      data key `sshPrivateKey`. Tenant uploads via Zitadel SSO under
#      the `tenant_<slug>` role grant.
#
#   2. **SSH key, literal** (legacy — entry has `repo_ssh_key_id: <id>`
#      AND operator put the key value into `var.argocd_repo_ssh_keys[<id>]`
#      via `TF_VAR_argocd_repo_ssh_keys` in `.env`). Engine emits the
#      historical `kubernetes_secret_v1` with the data inlined. Path
#      forward is to migrate every entry to mode 1.
#
#   3. **GitHub App, Vault** (entry has `repo_app_pem_id` +
#      `repo_app_id` + `repo_app_installation_id`). Engine emits a
#      `VaultStaticSecret` CR pointing at
#      `secret/data/tenants/<slug>/argocd-github-apps/<pem_id>` with
#      one data key `githubAppPrivateKey`. The `<app_id>` and
#      `<installation_id>` are templated in from the yaml (operator-
#      visible IDs — not secret). VSO renders the full Argo CD
#      repository Secret schema (`type` + `url` + `githubAppID` +
#      `githubAppInstallationID` + `githubAppPrivateKey`).
#
#      Use when one GitHub App on the org pulls many repos — single
#      PEM in Vault, multiple `argocd_bootstraps:` entries reuse the
#      same `repo_app_pem_id` across repos. Auth-trail in GitHub
#      surfaces as the App rather than a deploy key per repo.
#
# Per-entry: an entry must set EITHER `repo_ssh_key_id` OR
# `repo_app_pem_id` (with the two ID fields), never both — a plan-
# time check below catches the conflict.

variable "argocd_repo_ssh_keys" {
  description = "LEGACY operator-supplied map of `<id>` => SSH private key (PEM string). Each id present here picks the literal-emit path: engine writes the value straight into a `kubernetes_secret_v1` in the Argo CD namespace. Empty map (default) pushes EVERY referenced `repo_ssh_key_id` into Vault-mode — engine emits a `VaultStaticSecret` instead, and the matching tenant uploads the key into Vault under `secret/data/tenants/<slug>/argocd-deploy-keys/<id>` themselves. New work should not add to this map; left in place for the migration window."
  type        = map(string)
  default     = {}
}

locals {
  # Flat list of every `argocd_bootstraps:` entry across every project,
  # tagged with the credential mode (ssh / app) and the per-mode
  # discriminator (cred_id). Slug = the project's tenant identity,
  # determines the Vault path the credential lives at and whose Zitadel
  # role can write it. `distinct()` collapses duplicates so multiple
  # envs sharing one deploy repo produce one Secret per tenant.
  _argocd_repo_entries = distinct(flatten([
    for _, project in local.projects : [
      for _, entry in try(project.argocd_bootstraps, {}) :
      try(entry.repo_app_pem_id, "") != "" ? {
        mode                = "app"
        url                 = try(entry.repo_url, "")
        slug                = project.slug
        cred_id             = try(entry.repo_app_pem_id, "")
        app_id              = tostring(try(entry.repo_app_id, ""))
        app_installation_id = tostring(try(entry.repo_app_installation_id, ""))
        } : (try(entry.repo_ssh_key_id, "") != "" ? {
          mode                = "ssh"
          url                 = try(entry.repo_url, "")
          slug                = project.slug
          cred_id             = try(entry.repo_ssh_key_id, "")
          app_id              = ""
          app_installation_id = ""
      } : null)
      if try(entry.repo_url, "") != "" && (try(entry.repo_ssh_key_id, "") != "" || try(entry.repo_app_pem_id, "") != "")
    ]
  ]))

  # Stable for_each key. cred_id first so Secret names group by
  # operator intent (one credential spans many repos → all those
  # Secrets share a prefix); url-hash suffix disambiguates.
  argocd_repo_creds = {
    for pair in local._argocd_repo_entries :
    "${pair.cred_id}-${substr(md5(pair.url), 0, 8)}" => pair
  }

  # Per-mode partition.
  # - literal: `repo_ssh_key_id` present in `var.argocd_repo_ssh_keys`
  # - ssh_vault: ssh-mode entry NOT in `var.argocd_repo_ssh_keys`
  # - app_vault: app-mode entry (always Vault — PEMs are too large to
  #              live in TF_VAR_*)
  argocd_repo_creds_literal = {
    for k, v in local.argocd_repo_creds : k => v
    if v.mode == "ssh" && contains(keys(var.argocd_repo_ssh_keys), v.cred_id)
  }
  argocd_repo_creds_ssh_vault = {
    for k, v in local.argocd_repo_creds : k => v
    if v.mode == "ssh" && !contains(keys(var.argocd_repo_ssh_keys), v.cred_id)
  }
  argocd_repo_creds_app_vault = {
    for k, v in local.argocd_repo_creds : k => v
    if v.mode == "app"
  }

  # Backwards-compat alias — historical name. Tests / external refs
  # that grep for `argocd_repo_creds_vault` keep resolving to the
  # SSH-Vault subset.
  argocd_repo_creds_vault = local.argocd_repo_creds_ssh_vault

  # Whether ANY Vault-mode cred exists (ssh or app). Drives the
  # VSO-proxy ServiceAccount creation in the Argo CD namespace.
  _argocd_has_any_vault_creds = (
    length(local.argocd_repo_creds_ssh_vault) > 0 ||
    length(local.argocd_repo_creds_app_vault) > 0
  )
}

# Plan-time guard: catch entries that set both ssh + app credentials
# (ambiguous which the engine should emit) or app-mode entries missing
# the ID fields (engine would emit a Secret that Argo CD rejects at
# runtime — push the failure to plan instead).
check "argocd_bootstraps_credential_shape" {
  assert {
    condition = alltrue([
      for _, project in local.projects : alltrue([
        for _, entry in try(project.argocd_bootstraps, {}) :
        !(try(entry.repo_ssh_key_id, "") != "" && try(entry.repo_app_pem_id, "") != "")
      ])
    ])
    error_message = "argocd_bootstraps entry sets BOTH repo_ssh_key_id and repo_app_pem_id — pick one credential mode per entry."
  }

  assert {
    condition = alltrue([
      for _, project in local.projects : alltrue([
        for _, entry in try(project.argocd_bootstraps, {}) :
        try(entry.repo_app_pem_id, "") == "" || (
          try(entry.repo_app_id, "") != "" &&
          try(entry.repo_app_installation_id, "") != ""
        )
      ])
    ])
    error_message = "argocd_bootstraps entry with repo_app_pem_id must also set repo_app_id and repo_app_installation_id."
  }
}

resource "kubernetes_secret_v1" "argocd_repo" {
  for_each = local.platform.services.argocd.enabled ? local.argocd_repo_creds_literal : {}

  metadata {
    name      = "repo-${each.key}"
    namespace = local.platform.services.argocd.namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
      "app.kubernetes.io/managed-by"   = "terraform"
    }
  }

  data = {
    type          = "git"
    url           = each.value.url
    sshPrivateKey = var.argocd_repo_ssh_keys[each.value.cred_id]
  }
}

# Vault mode (any flavour) requires VSO's consuming-namespace SA in the
# Argo CD ns — VSO impersonates this SA when authenticating against
# Vault's k8s auth method (see feedback_vso_impersonates_consuming_namespace_sa).
# Engine emits the SA on demand: only when at least one repo cred is
# in any Vault mode (ssh or app), no SA otherwise.
resource "kubernetes_service_account_v1" "argocd_vso_proxy" {
  count = local.platform.services.argocd.enabled && local._argocd_has_any_vault_creds ? 1 : 0

  depends_on = [kubernetes_namespace_v1.argocd]

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = local.platform.services.argocd.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubectl_manifest" "argocd_repo_vault" {
  for_each = local.platform.services.argocd.enabled ? local.argocd_repo_creds_ssh_vault : {}

  depends_on = [kubernetes_service_account_v1.argocd_vso_proxy]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "repo-${each.key}"
      namespace = local.platform.services.argocd.namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      vaultAuthRef = ""
      mount        = "secret"
      type         = "kv-v2"
      path         = "tenants/${each.value.slug}/argocd-deploy-keys/${each.value.cred_id}"
      destination = {
        name   = "repo-${each.key}"
        create = true
        labels = {
          "argocd.argoproj.io/secret-type" = "repository"
        }
        # VSO templating: combine the operator-provided `sshPrivateKey`
        # from Vault with the engine-known static `type` + `url` so the
        # rendered Secret matches Argo CD's repository-Secret schema.
        # `excludeRaw` drops VSO's default `_raw` JSON dump (whole
        # Vault response as one blob) — Argo CD's repo Secret schema
        # has no place for it and extra fields confuse the SSH client
        # (`_raw` showed up as the offending difference vs. legacy
        # literal-mode Argo CD repo Secrets that work).
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates = {
            type          = { text = "git" }
            url           = { text = each.value.url }
            sshPrivateKey = { text = "{{- get .Secrets \"sshPrivateKey\" -}}" }
          }
        }
      }
      refreshAfter = "30s"
    }
  })
}

# GitHub App, Vault-only. PEM lives in Vault; the operator-visible
# `app_id` + `app_installation_id` come from the yaml (not secret —
# safe to leak). VSO renders the same shape as the SSH path but
# swaps `sshPrivateKey` for the three githubApp* fields Argo CD
# expects.
resource "kubectl_manifest" "argocd_repo_app_vault" {
  for_each = local.platform.services.argocd.enabled ? local.argocd_repo_creds_app_vault : {}

  depends_on = [kubernetes_service_account_v1.argocd_vso_proxy]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "repo-${each.key}"
      namespace = local.platform.services.argocd.namespace
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      vaultAuthRef = ""
      mount        = "secret"
      type         = "kv-v2"
      path         = "tenants/${each.value.slug}/argocd-github-apps/${each.value.cred_id}"
      destination = {
        name   = "repo-${each.key}"
        create = true
        labels = {
          "argocd.argoproj.io/secret-type" = "repository"
        }
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates = {
            type                    = { text = "git" }
            url                     = { text = each.value.url }
            githubAppID             = { text = each.value.app_id }
            githubAppInstallationID = { text = each.value.app_installation_id }
            githubAppPrivateKey     = { text = "{{- get .Secrets \"githubAppPrivateKey\" -}}" }
          }
        }
      }
      refreshAfter = "30s"
    }
  })
}
