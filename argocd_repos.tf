# Argo CD repo credential Secrets.
#
# Generic mechanism: operator supplies SSH private keys via
# `var.argocd_repo_ssh_keys` (map of `<id>` => PEM-encoded key).
# Components with `kind: argocd_app` reference an entry by `id`
# through the `repo_ssh_key_id:` field in their gitignored yaml. TF
# collects unique (repo_url, ssh_key_id) pairs across all such
# components and emits one Secret per pair in the Argo CD namespace,
# shaped per Argo CD's repository-secret convention (label
# `argocd.argoproj.io/secret-type: repository` + data {type, url,
# sshPrivateKey}). Multiple components pointing at the same repo with
# the same key reuse one Secret; different keys for the same URL get
# distinct Secrets — Argo CD's match-by-URL semantics tolerate either.
#
# Mirrors the existing `git_deploy_keys` mechanism (per-namespace
# git-sync key Secrets) — same private key value can serve both if
# the operator adds it as a deploy key on every consuming repo, but
# the maps are separate so an operator can scope keys narrowly.

variable "argocd_repo_ssh_keys" {
  description = "Operator-supplied map of `<id>` => SSH private key (PEM string). Components reference an entry by `repo_ssh_key_id:` in the domain yaml's `argocd_bootstrap:` block. Empty map = no private repo support; bootstrap repo must be public. NOT marked sensitive at the variable level so `for_each` over keys works; the rendered Secret's `data` block is sensitive in state."
  type        = map(string)
  default     = {}
}

locals {
  # (url, ssh_key_id) pairs across every project that declares an
  # `argocd_bootstrap:` block with a private-repo auth hint. Iterates
  # per-project from `local.projects[*].argocd_bootstrap`. `distinct()`
  # collapses duplicates so multiple envs sharing a deploy repo produce
  # one Secret.
  _argocd_app_repo_pairs = distinct([
    for _, project in local.projects : {
      url        = try(project.argocd_bootstrap.repo_url, "")
      ssh_key_id = try(project.argocd_bootstrap.repo_ssh_key_id, "")
    }
    if try(project.argocd_bootstrap, null) != null
    && try(project.argocd_bootstrap.repo_ssh_key_id, "") != ""
    && try(project.argocd_bootstrap.repo_url, "") != ""
  ])

  # Stable for_each key. Key id first so Secret names group by operator
  # intent (one key spans many repos → all those Secrets share a prefix);
  # url-hash suffix disambiguates.
  argocd_repo_creds = {
    for pair in local._argocd_app_repo_pairs :
    "${pair.ssh_key_id}-${substr(md5(pair.url), 0, 8)}" => pair
  }
}

# Precondition: every referenced ssh_key_id resolves in the operator's
# var.argocd_repo_ssh_keys map. Surfaces as a clear plan-time error
# instead of a sync-time `permission denied` from Argo CD's repo pull.
check "argocd_repo_ssh_keys_resolved" {
  assert {
    condition = alltrue([
      for pair in local._argocd_app_repo_pairs :
      contains(keys(var.argocd_repo_ssh_keys), pair.ssh_key_id)
    ])
    error_message = "argocd_bootstrap entry references a `repo_ssh_key_id` not present in `var.argocd_repo_ssh_keys`. Referenced ids: ${jsonencode([for p in local._argocd_app_repo_pairs : p.ssh_key_id])}. Available ids: ${jsonencode(keys(var.argocd_repo_ssh_keys))}. Add the missing entry to `terraform.tfvars` (`argocd_repo_ssh_keys = { ... }`) or remove the `repo_ssh_key_id:` field from the domain yaml's argocd_bootstrap block if the repo is public."
  }
}

resource "kubernetes_secret_v1" "argocd_repo" {
  for_each = local.platform.services.argocd.enabled ? local.argocd_repo_creds : {}

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
