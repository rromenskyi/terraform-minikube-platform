# KEDA — event-driven autoscaling for Deployments and Jobs.
#
# Installs the KEDA operator, its metrics API server (registers the
# `external.metrics.k8s.io` APIService the HPA reads) and the admission
# webhooks. Tenants then ship their own `ScaledObject` / `ScaledJob`
# resources (namespaced, so a tenant AppProject's namespace-only
# whitelist admits them); the engine owns the cluster-scoped CRDs and
# the APIService through this chart.
#
# A Deployment scaled by a ScaledObject has its replica count owned by
# the HPA KEDA creates. Whoever else manages that Deployment must not
# fight it: Argo CD Applications ignore `/spec/replicas`, Terraform
# resources use `ignore_changes = [spec[0].replicas]`.

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

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "keda"
  tags = {
    "app.kubernetes.io/component" = "keda"
  }
}

resource "kubernetes_namespace_v1" "keda" {
  for_each = local.instances

  metadata {
    name   = var.namespace
    labels = module.label.tags
  }
}

resource "helm_release" "keda" {
  for_each = local.instances

  name       = "keda"
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  # Helm keeps one Secret per revision; each holds the full rendered
  # manifest, so unbounded history slowly fills etcd.
  max_history      = 3
  version          = var.version_pin
  namespace        = kubernetes_namespace_v1.keda["enabled"].metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [yamlencode({
    nodeSelector = var.node_selector
    tolerations  = var.tolerations
  })]
}
