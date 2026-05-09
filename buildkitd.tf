# BuildKit daemon — root wiring.
#
# Module owns the namespace, kubectl_manifest Deployment (CERN userns
# pattern), and ClusterIP Service. Operator drives toggle + tuning
# via `services.buildkitd` in `config/platform.yaml`. See
# `modules/buildkitd/main.tf` header for the trust model and the
# `kubectl_manifest`-vs-`kubernetes_deployment_v1` rationale.

module "buildkitd" {
  source = "./modules/buildkitd"

  context        = module.platform_label.context
  enabled        = local.platform.services.buildkitd.enabled
  image_tag      = local.platform.services.buildkitd.image_tag
  host_path      = local.platform.services.buildkitd.host_path
  mount_path     = local.platform.services.buildkitd.mount_path
  cpu_request    = local.platform.services.buildkitd.cpu_request
  cpu_limit      = local.platform.services.buildkitd.cpu_limit
  memory_request = local.platform.services.buildkitd.memory_request
  memory_limit   = local.platform.services.buildkitd.memory_limit

  readiness_initial_delay_seconds = local.platform.services.buildkitd.readiness_initial_delay_seconds
  readiness_period_seconds        = local.platform.services.buildkitd.readiness_period_seconds
  readiness_timeout_seconds       = local.platform.services.buildkitd.readiness_timeout_seconds
  readiness_failure_threshold     = local.platform.services.buildkitd.readiness_failure_threshold

  node_selector = local.platform.services.buildkitd.node_selector
  tolerations   = local.platform.services.buildkitd.tolerations
}

output "buildkitd_endpoint" {
  description = "In-cluster BuildKit gRPC endpoint for `docker buildx create --driver remote --endpoint <this>`. Empty when buildkitd is disabled."
  value       = module.buildkitd.endpoint
}
