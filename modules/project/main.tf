terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

variable "project_config" {
  description = "Expanded project/env entry from locals.projects"
  type        = any
}

variable "components" {
  description = "Map of all available components from config/components/"
  type        = any
}

variable "default_limits" {
  description = "Default resource quota limits"
  type        = any
}

variable "mysql_namespace" {
  description = "Namespace where the shared MySQL lives"
  type        = string
}

variable "mysql_host" {
  description = "In-cluster hostname of the shared MySQL"
  type        = string
}

variable "volume_base_path" {
  description = "Base path for hostPath volumes inside the minikube node"
  type        = string
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  namespace = var.project_config.namespace # e.g. "example-com-prod"
  domain    = var.project_config.name      # e.g. "example.com"
  env       = var.project_config.env       # e.g. "prod"

  component_defaults = {
    image           = "nginx:alpine"
    port            = 80
    replicas        = 2
    health_path     = "/"
    ingress_enabled = true
    db              = false
    storage         = []
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
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
        # Prod: web.example.com  |  Staging: web.staging.example.com
        domain = try(
          component.domain,
          local.env == "prod"
          ? "${name}.${local.domain}"
          : "${name}.${local.env}.${local.domain}"
        )
        # Aliases: extra hostnames that route to the same service.
        # "" = bare domain (example.org), "www" = www.example.org
        all_domains = concat(
          [try(
            component.domain,
            local.env == "prod"
            ? "${name}.${local.domain}"
            : "${name}.${local.env}.${local.domain}"
          )],
          [for alias in try(
            coalescelist(try(component.aliases, []), try(lookup(var.components, name, {}).aliases, [])),
            []
            ) :
            alias == "" ? local.domain : (
              local.env == "prod"
              ? "${alias}.${local.domain}"
              : "${alias}.${local.env}.${local.domain}"
            )
          ]
        )
      }
    )
  }

  routed_components = {
    for name, c in local.normalized_components :
    name => c
    if try(c.ingress_enabled, true) && try(c.enabled, true)
  }

  needs_db = anytrue([
    for _, c in local.normalized_components : try(c.db, false)
  ])

  db_name = replace(local.namespace, "-", "_")
  db_user = replace(local.namespace, "-", "_")
}

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = local.domain
      "environment"                  = local.env
    }
  }
}

# ── Resource Quota ────────────────────────────────────────────────────────────

resource "kubernetes_resource_quota_v1" "limits" {
  metadata {
    name      = "limits"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    hard = {
      "limits.cpu"      = try(var.project_config.limits.cpu, var.default_limits.cpu, "2")
      "limits.memory"   = try(var.project_config.limits.memory, var.default_limits.memory, "4Gi")
      "requests.cpu"    = try(var.project_config.limits.cpu, var.default_limits.cpu, "2")
      "requests.memory" = try(var.project_config.limits.memory, var.default_limits.memory, "4Gi")
    }
  }
}

# ── MySQL: DB + User + Secret (only when at least one component needs db) ─────

resource "random_password" "db" {
  count   = local.needs_db ? 1 : 0
  length  = 24
  special = false
}

# Provisions the DB and user inside the shared MySQL via a Kubernetes Job.
# The Job runs a mysql client container in-cluster — no dependency on local
# kubectl or shell escaping. Database is intentionally NOT dropped on destroy
# to preserve data.
resource "kubernetes_job_v1" "mysql_setup" {
  count = local.needs_db ? 1 : 0

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "db-setup-${local.namespace}"
    namespace = var.mysql_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "db-setup-${local.namespace}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "mysql-setup"
          image = "mysql:8.0"

          env_from {
            secret_ref {
              name = "mysql-root"
            }
          }

          command = [
            "sh", "-c",
            join("", [
              "mysql -h ${var.mysql_host} -uroot ",
              "-p\"$MYSQL_ROOT_PASSWORD\" -e \"",
              "CREATE DATABASE IF NOT EXISTS \\`${local.db_name}\\`;",
              "CREATE USER IF NOT EXISTS '${local.db_user}'@'%' ",
              "IDENTIFIED BY '${random_password.db[0].result}';",
              "GRANT ALL PRIVILEGES ON \\`${local.db_name}\\`.* TO '${local.db_user}'@'%';",
              "FLUSH PRIVILEGES;\"",
            ])
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "2m"
  }
}

resource "kubernetes_secret_v1" "db_credentials" {
  count = local.needs_db ? 1 : 0

  depends_on = [kubernetes_job_v1.mysql_setup]

  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    DB_HOST = var.mysql_host
    DB_PORT = "3306"
    DB_NAME = local.db_name
    DB_USER = local.db_user
    DB_PASS = random_password.db[0].result
  }
}

# ── Components ────────────────────────────────────────────────────────────────

module "component" {
  for_each = {
    for name, c in local.normalized_components : name => c
    if try(c.enabled, true)
  }

  source = "../component"

  name      = each.key
  namespace = kubernetes_namespace_v1.this.metadata[0].name
  image     = each.value.image
  port      = each.value.port
  replicas  = each.value.replicas
  resources = each.value.resources

  health_path      = try(each.value.health_path, "/")
  storage          = try(each.value.storage, [])
  volume_base_path = var.volume_base_path

  db_env_mapping = try(each.value.env, {})
  db_secret_name = try(each.value.db, false) && local.needs_db ? (
    kubernetes_secret_v1.db_credentials[0].metadata[0].name
  ) : null

  config_files = try(each.value.config_files, {})
}

# ── IngressRoutes ─────────────────────────────────────────────────────────────

resource "kubectl_manifest" "ingressroute" {
  for_each = local.routed_components

  depends_on = [module.component]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = each.key
      namespace = local.namespace
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = join(" || ", [for d in each.value.all_domains : "Host(`${d}`)"])
        kind  = "Rule"
        services = [{
          name = each.key
          port = tostring(each.value.port)
        }]
      }]
      tls = {
        certResolver = "letsencrypt-production"
      }
    }
  })
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "domain" {
  value = local.domain
}

output "env" {
  value = local.env
}

output "hostnames" {
  value = merge([
    for name, c in local.routed_components : {
      for d in c.all_domains : d => {
        component = name
        service   = "http://${name}.${local.namespace}.svc.cluster.local:${c.port}"
        zone_id   = try(var.project_config.cloudflare_zone_id, null)
      }
    }
  ]...)
}

output "components" {
  value = keys(local.normalized_components)
}

output "has_db" {
  value = local.needs_db
}
