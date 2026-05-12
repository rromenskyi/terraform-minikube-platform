# GitHub self-hosted runners via ARC (Actions Runner Controller).
#
# Modern path: GitHub-maintained ARC v0.9+ ships two charts —
# `gha-runner-scale-set-controller` (one per cluster, watches the
# AutoscalingRunnerSet CRD) and `gha-runner-scale-set` (one per
# runner pool, registers with a specific org / repo / enterprise
# URL via the GitHub Actions API). The controller's listener-pod
# pattern replaced the older KEDA-based ARC: it polls GitHub for
# queued workflow_jobs and creates / deletes runner pods directly,
# scaling 0 → max_runners and back as the queue drains. No KEDA
# needed.
#
# Authentication is per-scale-set: either a GitHub App (org-wide,
# preferred) or a PAT (token-scoped to a single org / repo / user
# context). The engine accepts both via the operator-supplied
# Secret name input — engine doesn't store the credential, just
# wires the Secret reference into the chart values.
#
# Source-IP / network egress: runners pull from GitHub's HTTPS API
# only — no L4 ingress need on the cluster side, no MetalLB
# concern. Outbound bandwidth + image-pull caching is the usual
# bottleneck on self-hosted; sizing comes from the operator's
# observed CI workload.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}


# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances         = var.enabled ? toset(["enabled"]) : toset([])
  scale_set_targets = var.enabled ? var.scale_sets : {}
  # Each scale set lands in its own namespace — engine creates them
  # idempotently rather than asking the operator to pre-create.
  scale_set_namespaces = distinct([for _, s in local.scale_set_targets : s.namespace])

  # Scale sets in vault-mode — operator places the PAT in Vault under
  # `secret/data/platform/github-runner-tokens/<scale-set-key>` (one
  # data key: `github_token`); engine emits a VaultStaticSecret CR
  # per entry, VSO syncs into a `<scale-set-key>-github-pat` Secret in
  # the scale set's namespace. Chart consumes the same Secret name as
  # in operator-tokens-mode — only the source-of-truth differs.
  vault_mode_targets = {
    for k, v in local.scale_set_targets :
    k => v
    if try(v.vault, false)
  }

  # VSO impersonates the SA in the consuming namespace (per
  # feedback_vso_impersonates_consuming_namespace_sa) — it must exist
  # in every namespace running a VaultStaticSecret. Engine emits one
  # per distinct namespace that contains at least one vault-mode
  # scale set.
  vso_proxy_namespaces = distinct([for _, s in local.vault_mode_targets : s.namespace])

  # Shorthand for the propagated null-label tag set used by every
  # non-Helm resource the module emits. Helm releases delegate label
  # generation to their charts (gha-runner-scale-set-controller and
  # gha-runner-scale-set), so we don't apply `metadata.labels` to the
  # `helm_release` TF resource — the chart's own values block owns
  # the runtime labels. Only the engine-emitted glue (namespaces +
  # the engine-emitted PAT Secret) carries our null-label tags.
  tags = module.label.tags
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace_controller
  name      = "github-runners"
  tags = {
    "app.kubernetes.io/component" = "github-runners"
  }
}

# ── Controller namespace + chart ───────────────────────────────────────────

resource "kubernetes_namespace_v1" "controller" {
  for_each = local.instances

  metadata {
    name = var.namespace_controller
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-controller"
    })
  }
}

resource "helm_release" "controller" {
  for_each = local.instances

  name             = "arc-controller"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = var.controller_chart_version
  namespace        = kubernetes_namespace_v1.controller["enabled"].metadata[0].name
  create_namespace = false

  values = [yamlencode({
    nodeSelector = var.controller_node_selector
    tolerations  = var.controller_tolerations
  })]
}

# ── Per-scale-set namespaces ───────────────────────────────────────────────

resource "kubernetes_namespace_v1" "scale_set" {
  for_each = toset(local.scale_set_namespaces)

  metadata {
    name = each.key
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-runners"
    })
  }
}

# ── Engine-emitted PAT Secret per scale set (operator-tokens-mode) ─────────
#
# Triggers when the operator supplied a token in `var.tokens[<key>]`
# AND the scale-set entry left `github_secret_name` empty AND
# `vault: true` is NOT set. Engine creates `<key>-github-pat`
# carrying the `github_token` field the chart's listener-pod
# expects. Legacy `.env`-bound mode — vault-mode (below) is the
# preferred path for new entries.
resource "kubernetes_secret_v1" "github_pat" {
  # Token VALUES are sensitive; their KEYS aren't (they match
  # operator-yaml scale-set names that already live unencrypted in
  # `services.github_runners.scale_sets`). `nonsensitive(keys(...))`
  # unwraps just the key list so for_each can iterate at plan time.
  for_each = {
    for k, v in local.scale_set_targets :
    k => v
    if v.github_secret_name == "" && !try(v.vault, false) && contains(nonsensitive(keys(var.tokens)), k)
  }

  depends_on = [kubernetes_namespace_v1.scale_set]

  metadata {
    name      = "${each.key}-github-pat"
    namespace = each.value.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-github-pat"
      "platform.scale-set"           = each.key
    })
  }

  data = {
    github_token = var.tokens[each.key]
  }
}

# ── VSO consuming-namespace SA (vault-mode prerequisite) ───────────────────
#
# VSO impersonates the SA in the namespace WHERE the VaultStaticSecret
# CR lives (not its own ns) when calling Vault's k8s auth method —
# see feedback_vso_impersonates_consuming_namespace_sa.md. The default
# VaultAuth installed by the vault module references a SA name that
# must exist in every namespace running a VaultStaticSecret. Engine
# emits one per scale-set namespace with at least one vault-mode
# entry; without it VSO fails reconcile with "ServiceAccount not
# found" and never materialises the Secret.
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = toset(local.vso_proxy_namespaces)

  depends_on = [kubernetes_namespace_v1.scale_set]

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = each.key
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-vso-proxy"
    })
  }
}

# ── Vault-mode PAT (preferred path for new entries) ────────────────────────
#
# Triggers when scale-set entry has `vault: true`. Engine emits a
# VaultStaticSecret CR pointing at the convention path
# `secret/data/platform/github-runner-tokens/<scale-set-key>`
# (operator places the PAT under one data key: `github_token`).
# VSO syncs into a `<scale-set-key>-github-pat` Secret in the scale
# set's namespace — same name the chart's listener-pod expects, so
# downstream wiring is identical to operator-tokens-mode.
#
# Operator path: open Vault UI → Secrets → secret/ → Create →
# `platform/github-runner-tokens/<scale-set-key>` → set one key
# `github_token` to the `ghp_*` value. No `.env` entry needed.
resource "kubectl_manifest" "github_pat_vault" {
  for_each = local.vault_mode_targets

  depends_on = [
    kubernetes_namespace_v1.scale_set,
    kubernetes_service_account_v1.vso_proxy,
  ]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "${each.key}-github-pat"
      namespace = each.value.namespace
      labels = merge(local.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "app.kubernetes.io/component"  = "arc-github-pat"
        "platform.scale-set"           = each.key
      })
    }
    spec = {
      # VSO falls back to the cluster-default VaultAuth in the
      # vault-secrets-operator namespace when vaultAuthRef is empty.
      # The platform's vault module enables that default at install
      # time (modules/vault/main.tf vso helm release values).
      vaultAuthRef = ""
      mount        = "secret"
      type         = "kv-v2"
      path         = "platform/github-runner-tokens/${each.key}"
      destination = {
        name   = "${each.key}-github-pat"
        create = true
      }
      # 30s catches a rotation in Vault UI within half a minute. Pod
      # restart on rotation is consumer's concern — for ARC the
      # listener pod also has known stickiness on PAT rotation that
      # may need the listener-config Secret to be deleted manually
      # (see feedback_arc_listener_config_secret_stale.md).
      refreshAfter = "30s"
    }
  })
}

# ── Scale sets ─────────────────────────────────────────────────────────────

resource "helm_release" "scale_set" {
  for_each = local.scale_set_targets

  depends_on = [
    helm_release.controller,
    kubernetes_namespace_v1.scale_set,
    kubernetes_secret_v1.github_pat,
    kubectl_manifest.github_pat_vault,
  ]

  # Catch the misconfiguration at plan time rather than at runtime as
  # a CrashLoopBackOff on the listener Pod. Each scale set must wire
  # GitHub auth via exactly one of three modes — vault (engine emits
  # VaultStaticSecret, operator places PAT in Vault UI), externally-
  # managed (operator pre-creates a Secret carrying GitHub App fields
  # and references it by name), or operator-tokens-mode (legacy
  # `.env` map). Without any of these, the chart installs but
  # `githubConfigSecret` points at a Secret that never gets created
  # and the listener Pod loops on "Secret not found".
  lifecycle {
    precondition {
      condition = (
        try(each.value.vault, false)
        || each.value.github_secret_name != ""
        || contains(nonsensitive(keys(var.tokens)), each.key)
      )
      error_message = "Scale set `${each.key}`: no GitHub auth wired. Pick one: (1) `vault: true` and place the PAT in Vault under `secret/data/platform/github-runner-tokens/${each.key}` (key `github_token`); (2) `github_secret_name: <name>` to reference an externally-managed Secret carrying GitHub App fields; (3) supply a PAT via `var.tokens[\"${each.key}\"]` (legacy `.env` mode) so the engine can emit `${each.key}-github-pat` automatically."
    }

    # Mutually-exclusive: vault-mode and externally-managed both
    # produce a Secret with the same name (`<key>-github-pat` vs
    # `github_secret_name`), and the chart can only mount one.
    # Operator-tokens-mode (`var.tokens[<key>]`) is intentionally
    # NOT in this check — vault-mode silently shadows it during the
    # migration window, so an operator can flip `vault: true`
    # without first deleting the entry from `.env`. Engine just
    # stops emitting the legacy `kubernetes_secret_v1.github_pat`
    # for that key (see for_each filter on that resource).
    precondition {
      condition     = !(try(each.value.vault, false) && each.value.github_secret_name != "")
      error_message = "Scale set `${each.key}`: `vault: true` is mutually exclusive with `github_secret_name`. Pick one auth source."
    }
  }

  name             = each.key
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.scale_set_chart_version
  namespace        = each.value.namespace
  create_namespace = false

  values = [yamlencode({
    githubConfigUrl = each.value.github_config_url
    # Either the operator referenced an externally-managed Secret
    # (GitHub App fields outside the scope of `var.tokens`) or
    # engine emitted a PAT Secret named after the scale-set key.
    githubConfigSecret = each.value.github_secret_name != "" ? each.value.github_secret_name : "${each.key}-github-pat"
    minRunners         = each.value.min_runners
    maxRunners         = each.value.max_runners
    template = {
      spec = {
        nodeSelector = each.value.runner_node_selector
        tolerations  = each.value.runner_tolerations
        affinity     = each.value.runner_affinity
        containers = [{
          name      = "runner"
          image     = each.value.runner_image
          command   = ["/home/runner/run.sh"]
          resources = each.value.runner_resources
        }]
      }
    }
  })]
}

