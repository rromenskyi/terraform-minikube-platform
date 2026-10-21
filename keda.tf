# KEDA — event-driven autoscaling.
#
# Cluster-wide operator + metrics API server; tenants ship their own
# ScaledObjects. Off by default; `services.keda.enabled` turns it on.
# See modules/keda/README.md for the replica-ownership rule (Argo CD /
# Terraform must not manage `spec.replicas` of a scaled Deployment).

module "keda" {
  source     = "./modules/keda"
  depends_on = [module.addons]

  context       = module.platform_label.context
  enabled       = local.platform.services.keda.enabled
  namespace     = local.platform.services.keda.namespace
  version_pin   = local.platform.services.keda.version_pin
  node_selector = local.platform.services.keda.node_selector
  tolerations   = local.platform.services.keda.tolerations
}
