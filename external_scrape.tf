# Prometheus scraping of devices outside the cluster (e.g. ESPHome smart
# plugs, a NAS, a UPS) that serve Prometheus metrics, optionally behind HTTP
# basic auth.
#
# Config shape (config/platform.yaml, gitignored):
#   monitoring:
#     external_targets:
#       <name>:                        # one Prometheus job per name
#         targets:
#           - address: 192.0.2.10      # host or host:port
#             labels: { plug: server-a, load: server }   # optional, per target
#         metrics_path: /metrics       # optional
#         scheme: http                 # optional: http | https
#         interval: 30s                # optional
#         basic_auth_user: admin       # optional; password: see below
#
# The basic-auth password is a secret, so it never sits in the config: set it
# in the sensitive variable `monitoring_scrape_passwords`, keyed by <name>
# (terraform.tfvars, gitignored). A Secret in `monitoring` carries it.
#
# Prometheus (kube-prometheus-stack) selects ScrapeConfigs labelled
# `release: kube-prometheus-stack` in its own namespace.

locals {
  _external_targets = try(local.platform.monitoring.external_targets, {})
}

resource "terraform_data" "external_targets_checks" {
  for_each = local._external_targets

  lifecycle {
    precondition {
      condition     = try(each.value.basic_auth_user, "") == "" || contains(keys(nonsensitive(var.monitoring_scrape_passwords)), each.key)
      error_message = "monitoring.external_targets.${each.key} sets basic_auth_user, but monitoring_scrape_passwords has no \"${each.key}\" entry (terraform.tfvars)."
    }
    precondition {
      condition     = length(try(each.value.targets, [])) > 0
      error_message = "monitoring.external_targets.${each.key} needs at least one target."
    }
  }
}

resource "kubernetes_secret_v1" "external_target_auth" {
  for_each   = { for name, t in local._external_targets : name => t if try(t.basic_auth_user, "") != "" }
  depends_on = [module.addons]

  metadata {
    name      = "scrape-${each.key}-auth"
    namespace = "monitoring"
    labels    = { "app.kubernetes.io/managed-by" = "terraform" }
  }

  data = {
    username = each.value.basic_auth_user
    password = var.monitoring_scrape_passwords[each.key]
  }
}

resource "kubectl_manifest" "external_target_scrape" {
  for_each   = local._external_targets
  depends_on = [module.addons, terraform_data.external_targets_checks]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1alpha1"
    kind       = "ScrapeConfig"
    metadata = {
      name      = each.key
      namespace = "monitoring"
      labels = {
        release                        = "kube-prometheus-stack"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = merge(
      {
        metricsPath    = try(each.value.metrics_path, "/metrics")
        scheme         = upper(try(each.value.scheme, "http"))
        scrapeInterval = try(each.value.interval, "30s")
        staticConfigs = [
          for t in each.value.targets : {
            targets = [t.address]
            labels  = try(t.labels, {})
          }
        ]
      },
      try(each.value.basic_auth_user, "") == "" ? {} : {
        basicAuth = {
          username = { name = "scrape-${each.key}-auth", key = "username" }
          password = { name = "scrape-${each.key}-auth", key = "password" }
        }
      }
    )
  })
}
