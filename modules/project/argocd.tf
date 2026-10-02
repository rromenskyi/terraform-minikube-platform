# ── ArgoCD wiring (per project) ──────────────────────────────────────────────
#
# Two ways the project intersects with Argo CD:
#
#   1. `argocd_hostnames:` map in the domain yaml — hostnames the
#      operator wants Argo CD-managed services reachable on. TF only
#      plumbs DNS + (optional) Cloudflare Tunnel ingress rule. The
#      IngressRoute itself + the Service it targets live in the
#      operator's deploy repo (chart-rendered, Argo CD-applied).
#
#   2. `argocd_bootstraps:` map in the domain yaml — keyed by short
#      name, each entry carries the repo URL + path + branch of one
#      operator deploy repo. TF emits ONE root Application per entry
#      (`<ns>-<key>-bootstrap`) plus a single AppProject scoping every
#      Application synced under any of them to this project's
#      namespace. Sub-Applications and AppProject overrides land in
#      the deploy repos themselves, not here. Multi-entry use case:
#      one chart per repo deployed into the same namespace (a backend
#      chart and a frontend chart in separate repos sharing one
#      project namespace, each owning its own Application manifest).
#
# When neither is declared, the project has zero Argo CD footprint.

# AppProject — RBAC scope. One per (project, env) when the project
# has any Argo CD wiring (bootstrap declared OR argocd_hostnames
# non-empty). Destinations pin strictly to this project's namespace;
# sourceRepos pin to the bootstrap deploy repo (sub-Applications
# inherit via `spec.project = <project-name>`). Cluster-scoped
# resources are entirely denied — the platform owns CRDs, ClusterRoles,
# Namespaces.
resource "kubectl_manifest" "argocd_app_project" {
  for_each = (length(var.argocd_bootstraps) > 0 || length(var.argocd_hostnames) > 0) ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = local.namespace
      namespace = var.argocd_namespace
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "platform.tenant"              = local.namespace
      })
    }
    spec = {
      description = "Auto-managed AppProject for TF project ${local.namespace}. Pins Application destinations to this namespace and source repos to every operator deploy repo declared under `argocd_bootstraps:`."

      sourceRepos = distinct(compact([
        for _, b in var.argocd_bootstraps : try(b.repo_url, "")
      ]))

      # Workloads only. The bootstrap's child Application objects go to
      # Argo CD's namespace through the separate `-bootstrap` project
      # below, so this project never grants anything else there.
      destinations = [
        {
          server    = "https://kubernetes.default.svc"
          namespace = local.namespace
        },
      ]

      namespaceResourceWhitelist = [
        { group = "*", kind = "*" },
      ]
      clusterResourceWhitelist = []
    }
  })
}

# Project of the bootstrap (App-of-Apps) Applications: may create only
# Argo CD `Application` objects, and only in Argo CD's namespace. With the
# workload project above, a tenant repo can't put ConfigMaps, Secrets or
# Pods into Argo CD's namespace.
resource "kubectl_manifest" "argocd_bootstrap_project" {
  for_each = length(var.argocd_bootstraps) > 0 ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "${local.namespace}-bootstrap"
      namespace = var.argocd_namespace
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "platform.tenant"              = local.namespace
      })
    }
    spec = {
      description = "Auto-managed bootstrap project for TF project ${local.namespace}: Application objects only, in Argo CD's namespace."
      sourceRepos = distinct(compact([
        for _, b in var.argocd_bootstraps : try(b.repo_url, "")
      ]))
      destinations = [
        {
          server    = "https://kubernetes.default.svc"
          namespace = var.argocd_namespace
        },
      ]
      namespaceResourceWhitelist = [
        { group = "argoproj.io", kind = "Application" },
      ]
      clusterResourceWhitelist = []
    }
  })
}

# Bootstrap Application — App-of-Apps root. Points at the operator's
# deploy repo path; Argo CD recursively syncs every Application
# manifest found there. Sub-Applications must declare
# `spec.project: <project-name>` to land workloads (AppProject above
# refuses anything else).
resource "kubectl_manifest" "argocd_bootstrap" {
  for_each = var.argocd_bootstraps

  depends_on = [kubectl_manifest.argocd_app_project, kubectl_manifest.argocd_bootstrap_project]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "${local.namespace}-${each.key}-bootstrap"
      namespace = var.argocd_namespace
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
      labels = merge(module.project_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
        "platform.tenant"              = local.namespace
        "platform.role"                = "bootstrap"
        "platform.bootstrap.key"       = each.key
      })
    }
    spec = {
      project = "${local.namespace}-bootstrap"

      source = {
        repoURL        = each.value.repo_url
        path           = try(each.value.path, ".")
        targetRevision = try(each.value.target_revision, "HEAD")
        # Bootstrap directory contains plain Application yaml manifests —
        # no Helm rendering at the bootstrap layer. directory.recurse
        # picks up nested folders so the operator can group apps
        # however they like.
        directory = {
          recurse = true
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.argocd_namespace
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=false",
          "ServerSideApply=true",
        ]
        retry = {
          limit = 3
          backoff = {
            duration    = "30s"
            factor      = 2
            maxDuration = "5m"
          }
        }
      }
    }
  })
}
