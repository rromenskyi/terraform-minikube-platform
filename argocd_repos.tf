# Argo CD repo credential Secrets.
#
# Per-tenant model: each `argocd_bootstraps:` entry lives under a project
# in the domain yaml; that project's `slug` (e.g. `ipsupport-us`) is the
# tenant the deploy-key Secret is owned by. Two emit modes per
# (url, ssh_key_id) pair, picked by the operator-provided
# `var.argocd_repo_ssh_keys` map:
#
#   1. **Vault** (default — operator did NOT add the key id to
#      `var.argocd_repo_ssh_keys`). Engine emits a `VaultStaticSecret`
#      CR pointing at `secret/data/tenants/<slug>/argocd-deploy-keys/<id>`.
#      Tenant authenticates against Vault via Zitadel SSO with the
#      `tenant_<slug>` role grant and writes the key under that path
#      themselves (Vault UI: Secrets → secret/ → tenants/<slug>/argocd-deploy-keys/<id>
#      with one data key `sshPrivateKey`). VSO syncs into a Secret in
#      the Argo CD namespace; templating layers in the static
#      `type=git` + `url=<repo_url>` fields the chart needs alongside
#      the SSH key.
#
#   2. **Literal** (legacy — operator put the key value into
#      `var.argocd_repo_ssh_keys[<id>]` via `TF_VAR_argocd_repo_ssh_keys`
#      in `.env`). Engine emits the historical `kubernetes_secret_v1`
#      with the data inlined. Path forward is to migrate every entry
#      to mode 1 — keeps `.env` lean and lets tenants self-serve.
#
# Argo CD's match-by-URL semantics tolerate either shape — once the
# Secret carries the right `url` + `sshPrivateKey`, repo pulls work.

variable "argocd_repo_ssh_keys" {
  description = "LEGACY operator-supplied map of `<id>` => SSH private key (PEM string). Each id present here picks the literal-emit path: engine writes the value straight into a `kubernetes_secret_v1` in the Argo CD namespace. Empty map (default) pushes EVERY referenced `repo_ssh_key_id` into Vault-mode — engine emits a `VaultStaticSecret` instead, and the matching tenant uploads the key into Vault under `secret/data/tenants/<slug>/argocd-deploy-keys/<id>` themselves. New work should not add to this map; left in place for the migration window."
  type        = map(string)
  default     = {}
}

locals {
  # (slug, url, ssh_key_id) triples across every project's
  # `argocd_bootstraps:` map. Slug is the project's tenant identity —
  # determines the Vault path the deploy key lives at, and whose
  # Zitadel role can write it. `distinct()` collapses duplicates so
  # multiple envs / multiple bootstrap entries sharing one deploy
  # repo produce one Secret per tenant.
  _argocd_app_repo_pairs = distinct(flatten([
    for _, project in local.projects : [
      for _, entry in try(project.argocd_bootstraps, {}) : {
        url        = try(entry.repo_url, "")
        ssh_key_id = try(entry.repo_ssh_key_id, "")
        slug       = project.slug
      }
      if try(entry.repo_ssh_key_id, "") != "" && try(entry.repo_url, "") != ""
    ]
  ]))

  # Stable for_each key. Key id first so Secret names group by operator
  # intent (one key spans many repos → all those Secrets share a prefix);
  # url-hash suffix disambiguates.
  argocd_repo_creds = {
    for pair in local._argocd_app_repo_pairs :
    "${pair.ssh_key_id}-${substr(md5(pair.url), 0, 8)}" => pair
  }

  # Per-mode partition. Vault mode is implicit — any `repo_ssh_key_id`
  # NOT present in `var.argocd_repo_ssh_keys` resolves via Vault.
  argocd_repo_creds_literal = {
    for k, v in local.argocd_repo_creds : k => v
    if contains(keys(var.argocd_repo_ssh_keys), v.ssh_key_id)
  }
  argocd_repo_creds_vault = {
    for k, v in local.argocd_repo_creds : k => v
    if !contains(keys(var.argocd_repo_ssh_keys), v.ssh_key_id)
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
    sshPrivateKey = var.argocd_repo_ssh_keys[each.value.ssh_key_id]
  }
}

# Vault mode requires VSO's consuming-namespace SA in the Argo CD ns —
# VSO impersonates this SA when authenticating against Vault's k8s auth
# method (see feedback_vso_impersonates_consuming_namespace_sa). Engine
# emits the SA on demand: only when at least one repo cred is in vault
# mode, no SA otherwise.
resource "kubernetes_service_account_v1" "argocd_vso_proxy" {
  count = local.platform.services.argocd.enabled && length(local.argocd_repo_creds_vault) > 0 ? 1 : 0

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
  for_each = local.platform.services.argocd.enabled ? local.argocd_repo_creds_vault : {}

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
      path         = "tenants/${each.value.slug}/argocd-deploy-keys/${each.value.ssh_key_id}"
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
