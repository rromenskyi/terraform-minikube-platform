# Argo CD projects owned by the platform.
#
# `default` is created by Argo CD and allows every source, destination and
# cluster-scoped kind. Any Application object that names it — including
# one a tenant's bootstrap repo creates — could deploy anything anywhere,
# so it is emptied here. Platform-owned Applications use `platform`,
# limited to the repositories and namespaces in `var.platform_apps`.

resource "kubectl_manifest" "default_project" {
  for_each = local.instances

  depends_on = [helm_release.argocd]

  # Argo CD created the object; take over its spec.
  server_side_apply = true
  force_conflicts   = true

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "default"
      namespace = var.namespace
    }
    spec = {
      description              = "Locked: no sources or destinations. Use a named project."
      sourceRepos              = []
      destinations             = []
      clusterResourceWhitelist = []
    }
  })
}

resource "kubectl_manifest" "platform_project" {
  for_each = length(local.instances) > 0 && length(var.platform_apps) > 0 ? toset(["enabled"]) : toset([])

  depends_on = [helm_release.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "platform"
      namespace = var.namespace
    }
    spec = {
      description = "Platform-owned Applications."
      sourceRepos = distinct([for a in var.platform_apps : a.repo_url])
      destinations = [
        for ns in distinct([for a in var.platform_apps : a.namespace]) :
        { server = "https://kubernetes.default.svc", namespace = ns }
      ]
      namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
      clusterResourceWhitelist   = []
    }
  })
}
