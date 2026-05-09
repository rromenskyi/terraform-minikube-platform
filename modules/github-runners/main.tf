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
  }
}


# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances         = var.enabled ? toset(["enabled"]) : toset([])
  scale_set_targets = var.enabled ? var.scale_sets : {}
  # Each scale set lands in its own namespace — engine creates them
  # idempotently rather than asking the operator to pre-create.
  scale_set_namespaces = distinct([for _, s in local.scale_set_targets : s.namespace])
}

# ── Controller namespace + chart ───────────────────────────────────────────

resource "kubernetes_namespace_v1" "controller" {
  for_each = local.instances

  metadata {
    name = var.namespace_controller
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-controller"
    }
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
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-runners"
    }
  }
}

# ── Engine-emitted PAT Secret per scale set ───────────────────────────────
#
# Triggers when the operator supplied a token in `var.tokens[<key>]`
# AND the scale-set entry left `github_secret_name` empty (the
# default). Engine creates `<key>-github-pat` carrying the
# `github_token` field the chart's listener-pod expects. The
# operator's only knob is the `.env` map — no kubectl-create-secret
# anywhere in the workflow.
resource "kubernetes_secret_v1" "github_pat" {
  # Token VALUES are sensitive; their KEYS aren't (they match
  # operator-yaml scale-set names that already live unencrypted in
  # `services.github_runners.scale_sets`). `nonsensitive(keys(...))`
  # unwraps just the key list so for_each can iterate at plan time.
  for_each = {
    for k, v in local.scale_set_targets :
    k => v
    if v.github_secret_name == "" && contains(nonsensitive(keys(var.tokens)), k)
  }

  depends_on = [kubernetes_namespace_v1.scale_set]

  metadata {
    name      = "${each.key}-github-pat"
    namespace = each.value.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "arc-github-pat"
      "platform.scale-set"           = each.key
    }
  }

  data = {
    github_token = var.tokens[each.key]
  }
}

# ── Scale sets ─────────────────────────────────────────────────────────────

resource "helm_release" "scale_set" {
  for_each = local.scale_set_targets

  depends_on = [
    helm_release.controller,
    kubernetes_namespace_v1.scale_set,
    kubernetes_secret_v1.github_pat,
  ]

  # Catch the misconfiguration at plan time rather than at runtime as
  # a CrashLoopBackOff on the listener Pod. A scale-set entry with
  # `github_secret_name = ""` (engine-emit mode) requires a matching
  # entry in `var.tokens` so the engine can materialise the
  # `<key>-github-pat` Secret the chart's listener mounts. Without
  # the token, the chart still installs but `githubConfigSecret`
  # points at a Secret that never gets created — the listener Pod
  # then loops on "Secret not found" until somebody notices.
  lifecycle {
    precondition {
      condition     = each.value.github_secret_name != "" || contains(nonsensitive(keys(var.tokens)), each.key)
      error_message = "Scale set `${each.key}`: no GitHub auth wired. Either set `github_secret_name` to an externally-managed Secret carrying GitHub App fields, or supply a PAT via `var.tokens[\"${each.key}\"]` (operator typically pastes into `.env` as `TF_VAR_github_runner_tokens={ ${each.key} = \"ghp_...\" }`) so the engine can emit `${each.key}-github-pat` automatically."
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

