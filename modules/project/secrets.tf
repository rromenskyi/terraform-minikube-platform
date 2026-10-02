# ── Operator-defined Secrets (per-env `secrets:` block) ───────────────────────
#
# Three modes per entry, picked by yaml shape:
#
#   1. Random shared (default — entry has only `keys:`). Engine generates
#      ONE `random_password` per entry and writes it to every listed key.
#      Fits app-key style cases where a chart's `envFrom` exposes the
#      same shared bytes under multiple env names.
#
#   2. Vault (yaml entry has `vault: true`). Engine skips the literal
#      `kubernetes_secret_v1` and emits a `VaultStaticSecret` CR pointing
#      at the conventional path `secret/data/tenants/<project_slug>/<name>`.
#      VSO reconciles → creates k8s Secret with the same name in the
#      project namespace, copying every key/value from the Vault path
#      verbatim. Tenant rotates the Vault entry via UI/CLI; VSO re-syncs
#      within `refreshAfter` without TF re-apply. yaml `keys:` list is
#      advisory only (VSO doesn't filter); chart envFrom picks up
#      whatever's there.
#
#      Operator path: open Vault UI → Secrets → secret/ → Create →
#      `tenants/<slug>/<name>` → set the keys you want. Engine path
#      derivation is convention, NOT config — no .env entry, no
#      TF_VAR_operator_secret_values needed.
#
#   3. Literal (`var.operator_secret_values[<name>]` is a map of
#      key → value pairs — set via TF_VAR_operator_secret_values). Engine
#      writes the supplied k:v map straight into the Secret's data.
#      Plan-time check rejects partial coverage. Legacy escape-hatch for
#      operator credentials that haven't been migrated to Vault yet
#      (third-party storage, OIDC clients pre-vault). New work should
#      prefer mode (2).
#
# `random_password.operator_secret` is generated for every entry
# regardless of mode — cheap, kept in state, and lets an operator flip
# an entry to random by deleting its yaml `vault:` flag /
# `operator_secret_values` key without re-planning the random.

locals {
  # Per-entry mode: yaml `vault: true` wins; otherwise literal if
  # operator supplied values via TF_VAR; otherwise random.
  operator_secret_mode = {
    for name, entry in var.secrets :
    name => (
      try(entry.vault, false) == true
      ? "vault"
      : contains(keys(var.operator_secret_values), name) ? "literal" : "random"
    )
  }

  # nonsensitive() because for_each can't take a sensitive value (the
  # set membership reveals nothing — entry NAMES are config-yaml-public,
  # only the inner values are sensitive).
  operator_secret_literal_set = nonsensitive(toset([for n, m in local.operator_secret_mode : n if m == "literal"]))
  operator_secret_vault_set   = nonsensitive(toset([for n, m in local.operator_secret_mode : n if m == "vault"]))
  operator_secret_data_set    = nonsensitive(toset([for n, m in local.operator_secret_mode : n if m != "vault"]))

  # Vault path convention: `tenants/<slug>/<secret_name>`. Slug comes
  # from the project_config (locals.tf builds projects keyed
  # `<slug>-<env>` and stores `slug` as a top-level field). Same slug
  # the vault module uses for per-tenant policies + OIDC roles, so
  # tenant authenticated via Zitadel `tenant_<slug>` role can read /
  # write under this exact path.
  operator_secret_vault_paths = {
    for name in local.operator_secret_vault_set :
    name => "tenants/${var.project_config.slug}/${name}"
  }
}

resource "random_password" "operator_secret" {
  for_each = var.secrets

  length  = try(each.value.length, 48)
  special = false
}

resource "kubernetes_secret_v1" "operator_secret" {
  for_each = local.operator_secret_data_set

  metadata {
    name      = each.value
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = local.namespace
    })
  }

  data = (
    local.operator_secret_mode[each.value] == "literal"
    ? {
      for k in try(var.secrets[each.value].keys, []) :
      k => var.operator_secret_values[each.value][k]
    }
    : {
      for k in try(var.secrets[each.value].keys, []) :
      k => random_password.operator_secret[each.value].result
    }
  )
}

# VSO impersonates a ServiceAccount in the CONSUMING namespace (not
# its own) to obtain a JWT for Vault's k8s auth method. The default
# VaultAuth installed by the vault module references a SA name that
# must exist in every namespace running a VaultStaticSecret. Engine
# emits one per project namespace as a precondition — without this
# VSO fails reconcile with "ServiceAccount X not found" and never
# materialises the Secret.
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = (length(local.operator_secret_vault_set) > 0 || length(var.git_deploy_keys) > 0 || length(var.image_pull_secrets) > 0) ? toset(["enabled"]) : toset([])

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = local.namespace
    })
  }
}

# Tenant-scoped VaultAuth: VSO authenticates this namespace's
# VaultStaticSecrets with the tenant's own role (`var.vault_tenant_role`,
# limited to `tenants/<slug>/*`) instead of the shared default, which
# reads every tenant's and the platform's secrets.
resource "kubectl_manifest" "vault_auth" {
  for_each = length(kubernetes_service_account_v1.vso_proxy) > 0 && var.vault_tenant_role != "" ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "vault-tenant"
      namespace = kubernetes_namespace_v1.this.metadata[0].name
      labels    = merge(module.project_label.tags, { "app.kubernetes.io/managed-by" = "terraform" })
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role                   = var.vault_tenant_role
        serviceAccount         = kubernetes_service_account_v1.vso_proxy["enabled"].metadata[0].name
        tokenExpirationSeconds = 600
      }
    }
  })
}

# Vault-mode: emit a VaultStaticSecret CR that VSO reconciles into a
# k8s Secret with the same name in this project namespace. Path is
# convention-derived: `tenants/<tenant_slug>/<secret_name>` — operator
# only declares `vault: true` in yaml; the path the CR reads from in
# Vault is hardcoded by the engine. Operator must `vault kv put` at
# that exact path (UI: secret/ → tenants/<slug>/<name>) for VSO to
# find anything to sync.
resource "kubectl_manifest" "operator_secret_vault" {
  for_each = local.operator_secret_vault_set

  depends_on = [kubernetes_service_account_v1.vso_proxy, kubectl_manifest.vault_auth]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = each.value
      namespace = kubernetes_namespace_v1.this.metadata[0].name
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/part-of"    = local.namespace
      })
    }
    spec = {
      # The tenant VaultAuth above when a tenant role is set; otherwise
      # (empty ref) VSO's cluster-default VaultAuth.
      vaultAuthRef = local.vault_auth_ref
      mount        = "secret"
      type         = "kv-v2"
      path         = local.operator_secret_vault_paths[each.value]
      destination = {
        name   = each.value
        create = true
      }
      # 30s catches a rotation in Vault UI within half a minute.
      # Pod restart on rotation is consumer's concern (checksum
      # annotation pattern — see feedback_secret_consumer_needs_checksum_annotation).
      refreshAfter = "30s"
    }
  })
}

# ── git-sync deploy keys (Vault-backed) ──────────────────────────────────────
#
# Per-env yaml block `git_deploy_keys: { <id>: { host: github.com } }` →
# engine emits one `VaultStaticSecret` per entry pointing at the
# convention path `secret/data/tenants/<slug>/git-deploy-keys/<id>`.
# VSO reconciles into a `kubernetes.io/ssh-auth` Secret named
# `git-deploy-key-<id>` in the project namespace, with templating
# that combines the operator-supplied `sshPrivateKey` (from Vault)
# with the engine-known `known_hosts` line for `<host>`. Components
# reference the Secret via `git_sync.ssh_key_secret_name: git-deploy-key-<id>`.
#
# Curated `known_hosts` mirrors the static table the legacy
# root-level `git_deploy_keys.tf` carried — saves the operator from
# scraping `ssh-keyscan` for every common host. Add to the local
# below when a new host gets used.

locals {
  _git_known_hosts = {
    "github.com"    = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    "gitlab.com"    = "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf"
    "bitbucket.org" = "bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO"
  }
}

resource "kubectl_manifest" "git_deploy_key_vault" {
  for_each = var.git_deploy_keys

  depends_on = [kubernetes_service_account_v1.vso_proxy, kubectl_manifest.vault_auth]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "git-deploy-key-${each.key}"
      namespace = kubernetes_namespace_v1.this.metadata[0].name
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "git-deploy-key"
      })
    }
    spec = {
      vaultAuthRef = local.vault_auth_ref
      mount        = "secret"
      type         = "kv-v2"
      path         = "tenants/${var.project_config.slug}/git-deploy-keys/${each.key}"
      destination = {
        name   = "git-deploy-key-${each.key}"
        create = true
        type   = "kubernetes.io/ssh-auth"
        # Combine Vault's `sshPrivateKey` with the engine's static
        # `known_hosts` line for the chosen host. `excludeRaw` drops
        # VSO's default `_raw` JSON dump (k8s.io/ssh-auth Secret
        # schema would reject the extra field).
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates = {
            "ssh-privatekey" = { text = "{{- get .Secrets \"sshPrivateKey\" -}}" }
            "known_hosts" = { text = "${lookup(
              local._git_known_hosts,
              try(each.value.host, "github.com"),
              "${try(each.value.host, "github.com")} ssh-rsa <unknown — add this host to local._git_known_hosts in modules/project/main.tf>"
            )}\n" }
          }
        }
      }
      refreshAfter = "30s"
    }
  })
}

# ── image-pull Secrets (Vault-backed) ────────────────────────────────────────
#
# Per-env yaml block `image_pull_secrets: { <name>: { registry: ghcr.io } }`
# → engine emits one `VaultStaticSecret` per entry pointing at
# `secret/data/tenants/<slug>/image-pull-secrets/<name>`. The Vault
# path holds two keys: `username` + `token` (the operator-supplied
# PAT/username pair). VSO templates them with the engine-known
# `registry` into a single `.dockerconfigjson` body and writes it to
# a `kubernetes.io/dockerconfigjson` Secret named `<name>` in the
# project namespace. Chart references via `imagePullSecrets: [name: <name>]`.
#
# Long-lived classic PATs are the simplest source of truth for GHCR
# pulls today — fine-grained PATs don't expose Packages permission
# for org repos, and GitHub App installation tokens for ghcr.io
# aren't supported yet (as of early 2026). Rotation = re-`vault kv
# put` at the same path; VSO picks up within `refreshAfter`.

resource "kubectl_manifest" "image_pull_secret_vault" {
  for_each = var.image_pull_secrets

  depends_on = [kubernetes_service_account_v1.vso_proxy, kubectl_manifest.vault_auth]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = each.key
      namespace = kubernetes_namespace_v1.this.metadata[0].name
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "image-pull-secret"
      })
    }
    spec = {
      vaultAuthRef = local.vault_auth_ref
      mount        = "secret"
      type         = "kv-v2"
      path         = "tenants/${var.project_config.slug}/image-pull-secrets/${each.key}"
      destination = {
        name   = each.key
        create = true
        type   = "kubernetes.io/dockerconfigjson"
        # VSO template: base64(username:token) into the standard
        # dockerconfigjson shape. `excludeRaw` drops VSO's default
        # `_raw` JSON dump — k8s dockerconfigjson Secret schema only
        # accepts the single `.dockerconfigjson` key.
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates = {
            ".dockerconfigjson" = {
              text = "{\"auths\":{\"${try(each.value.registry, "ghcr.io")}\":{\"auth\":\"{{ printf \"%s:%s\" (get .Secrets \"username\") (get .Secrets \"token\") | b64enc }}\"}}}"
            }
          }
        }
      }
      refreshAfter = "30s"
    }
  })
}

# Patch the namespace's default ServiceAccount with imagePullSecrets
# pointing at every image-pull Secret declared above. Chart-side
# Deployments that don't explicitly set serviceAccountName inherit
# `default` and pick up these secrets automatically — tenants don't
# need to know the Secret name or wire `imagePullSecrets:` into
# every workload manifest.
resource "kubernetes_default_service_account_v1" "this" {
  for_each = length(var.image_pull_secrets) > 0 ? toset(["enabled"]) : toset([])

  metadata {
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  dynamic "image_pull_secret" {
    for_each = var.image_pull_secrets
    content {
      name = image_pull_secret.key
    }
  }

  # The default SA is auto-created by k8s; this resource adopts it
  # (kubernetes provider's documented pattern for managing built-in
  # objects). On destroy it removes the imagePullSecrets we added
  # but leaves the SA itself alone.
}
