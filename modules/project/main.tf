terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

variable "project_config" {
  description = "Parsed YAML from config/domains/*.yaml"
  type        = any
}

variable "components" {
  description = "Map of all available components from config/components/"
  type        = any
}

variable "default_limits" {
  description = "Default resource limits"
  type        = any
}

locals {
  project_domain = try(var.project_config.domain, var.project_config.name)

  component_defaults = {
    image           = "nginx:alpine"
    port            = 80
    replicas        = 2
    health_path     = "/"
    ingress_enabled = true
    resources = {
      requests = {
        cpu    = "100m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "512Mi"
      }
    }
  }

  component_inputs = {
    for component in try(var.project_config.components, []) :
    try(component.name, component) => component
  }

  normalized_components = {
    for name, component in local.component_inputs :
    name => merge(
      local.component_defaults,
      lookup(var.components, name, {}),
      try(merge(component, {}), {}),
      {
        domain = try(component.domain, "${name}.${local.project_domain}")
      }
    )
  }
}

# Create namespace for the project
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.project_config.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = var.project_config.name
      "environment"                  = try(var.project_config.environment, "prod")
    }
  }
}

# ResourceQuota per namespace
resource "kubernetes_resource_quota_v1" "limits" {
  metadata {
    name      = "limits"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    hard = {
      "limits.cpu"      = try(var.project_config.limits.cpu, var.default_limits.cpu, "2")
      "limits.memory"   = try(var.project_config.limits.memory, var.default_limits.memory, "4Gi")
      "requests.cpu"    = try(var.project_config.limits.cpu, var.default_limits.cpu, "1")
      "requests.memory" = try(var.project_config.limits.memory, var.default_limits.memory, "2Gi")
    }
  }
}

# Deploy all components for this project
module "component" {
  for_each = {
    for name, component in local.normalized_components :
    name => component if try(component.enabled, true)
  }

  source = "../component"

  name            = each.key
  namespace       = kubernetes_namespace_v1.this.metadata[0].name
  image           = each.value.image
  port            = each.value.port
  replicas        = each.value.replicas
  resources       = each.value.resources
  health_path     = try(each.value.health.path, each.value.health_path)
  ingress_enabled = try(each.value.ingress_enabled, true)
  domain          = each.value.domain
}

# TODO: Add synonyms (CNAME), additional IngressRoute, Cloudflare records

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}
