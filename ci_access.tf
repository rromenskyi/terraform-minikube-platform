# Kubernetes access for an external CI (e.g. GitHub Actions running Terraform
# against this cluster), under `services.ci_access` in the gitignored
# `config/platform.yaml`.
#
# A dedicated ServiceAccount with cluster-admin and a long-lived token. It is
# revocable on its own, without touching the cluster's admin certificate:
# delete the token Secret, apply, and re-export the kubeconfig. The
# `ci_kubeconfig` output renders one context per API server address in
# `api_servers` (e.g. the servers' WireGuard addresses the CI reaches), so a
# job can fall back to the next server when one is down. The
# server certificates must carry those addresses as SANs.
#
# The CI stores the kubeconfig as a secret of its own. Rotate by deleting the
# Secret `<name>-token`, applying, and updating the CI secret from
# `./tf output -raw ci_kubeconfig`.

locals {
  ci_access    = local.platform.services.ci_access
  ci_access_on = local.ci_access.enabled
}

resource "kubernetes_service_account_v1" "ci" {
  for_each = local.ci_access_on ? toset(["enabled"]) : toset([])

  metadata {
    name      = local.ci_access.name
    namespace = "kube-system"
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }
}

resource "kubernetes_secret_v1" "ci_token" {
  for_each = local.ci_access_on ? toset(["enabled"]) : toset([])

  metadata {
    name      = "${local.ci_access.name}-token"
    namespace = "kube-system"
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.ci["enabled"].metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# Terraform manages every kind of object in the cluster, so nothing narrower
# than cluster-admin can apply it.
resource "kubernetes_cluster_role_binding_v1" "ci" {
  for_each = local.ci_access_on ? toset(["enabled"]) : toset([])

  metadata {
    name   = local.ci_access.name
    labels = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.ci["enabled"].metadata[0].name
    namespace = "kube-system"
  }
}

output "ci_kubeconfig" {
  description = "Kubeconfig of the CI ServiceAccount (`services.ci_access`): one context per address in `api_servers` (`ci-0` is current). Store it as a CI secret; read with `./tf output -raw ci_kubeconfig`. Null when CI access is off."
  sensitive   = true
  value = local.ci_access_on ? yamlencode({
    apiVersion = "v1"
    kind       = "Config"
    clusters = [for i, server in local.ci_access.api_servers : {
      name = "ci-${i}"
      cluster = {
        server                       = server
        "certificate-authority-data" = base64encode(kubernetes_secret_v1.ci_token["enabled"].data["ca.crt"])
      }
    }]
    users = [{
      name = local.ci_access.name
      user = { token = kubernetes_secret_v1.ci_token["enabled"].data["token"] }
    }]
    contexts = [for i, server in local.ci_access.api_servers : {
      name    = "ci-${i}"
      context = { cluster = "ci-${i}", user = local.ci_access.name }
    }]
    "current-context" = "ci-0"
  }) : null
}
