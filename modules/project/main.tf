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
  description = "Parent path used verbatim by hostPath PersistentVolumes for every component in this project. Must resolve to a real writable directory from the kubelet's point of view. Forwarded unchanged to modules/component."
  type        = string
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  namespace = var.project_config.namespace # e.g. "phost-paseka-co-prod"
  domain    = var.project_config.name      # e.g. "paseka.co"
  env       = var.project_config.env       # e.g. "prod"
  routes    = try(var.project_config.routes, {}) # { "": whoami, www: whoami, api: whoami2 }

  # Components to deploy = every distinct value referenced by the routes
  # map. Hostnames and components are decoupled: the same component can
  # back multiple routes (www + bare), and different routes can pick
  # different components (api → whoami2, bare → whoami).
  _component_names = distinct([for _, c in local.routes : c])

  component_defaults = {
    image       = "nginx:alpine"
    port        = 80
    replicas    = 2
    health_path = "/"
    db          = false
    storage     = []
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { cpu = "200m", memory = "256Mi" }
    }
  }

  # Resolve each component's deploy spec from config/components/<name>.yaml.
  # Unknown component names are rejected by the precondition below rather
  # than being silently deployed as the defaults-only nginx fallback.
  #
  # Two component kinds are supported:
  #   - "deployment" (default): this project owns the workload. `module.component`
  #     creates a Deployment + Service from the spec below.
  #   - "external": the target Service already lives in the cluster (e.g.
  #     Grafana in the `monitoring` namespace, Traefik's internal API). No
  #     Deployment is created; the IngressRoute cross-references the existing
  #     Service by `name`+`namespace`+`port` (or `kind: TraefikService` for
  #     Traefik-internal references like `api@internal`).
  normalized_components = {
    for name in local._component_names :
    name => merge(
      { kind = "deployment" },
      local.component_defaults,
      lookup(var.components, name, {}),
    )
  }

  deployable_components = {
    for name, c in local.normalized_components :
    name => c if c.kind == "deployment"
  }

  external_components = {
    for name, c in local.normalized_components :
    name => c if c.kind == "external"
  }

  # Per-component list of fully-qualified hostnames. The host prefix from
  # the YAML route key is used literally — no env is injected. Empty key
  # = apex domain; every other key produces `{prefix}.{domain}`. If two
  # envs of the same domain need distinct hostnames, the operator writes
  # them explicitly (e.g. `whoami.dev: whoami` under `envs.dev.routes`).
  routes_by_component = {
    for component in local._component_names :
    component => [
      for host_prefix, target in local.routes :
      host_prefix == "" ? local.domain : "${host_prefix}.${local.domain}"
      if target == component
    ]
  }

  # IngressRoute `services[]` entries per component.
  #   deployable: in-namespace Service created by `module.component`.
  #   external + `ingress_service`: override to a `TraefikService`
  #     reference like `api@internal` (for the Traefik dashboard).
  #   external (plain): cross-namespace reference to a pre-existing Service
  #     — safe because the addons module enables
  #     `providers.kubernetesCRD.allowCrossNamespace=true` on Traefik.
  ir_service_refs = {
    for name, c in local.normalized_components :
    name => (
      try(c.ingress_service, null) != null
      ? { kind = c.ingress_service.kind, name = c.ingress_service.name }
      : c.kind == "external"
      ? {
        name      = c.service.name
        namespace = c.service.namespace
        port      = tostring(c.service.port)
      }
      : { name = name, port = tostring(c.port) }
    )
  }

  # Traefik entryPoints the IngressRoute answers on. Default is
  # `websecure` so TLS termination via `letsencrypt-production` works for
  # direct LAN ingress. Components that need `web` (HTTP on port 80) — e.g.
  # the Traefik dashboard, where cloudflared forwards HTTP straight to
  # Traefik's web entrypoint and expects an IR match there — override.
  ir_entry_points = {
    for name, c in local.normalized_components :
    name => try(c.entry_points, ["websecure"])
  }

  # URL cloudflared forwards this route's requests to.
  #   deployable: the in-namespace Service (bypasses Traefik).
  #   external: the service named in the component spec. For a TraefikService
  #     passthrough (dashboard), that's Traefik's own web entrypoint — the
  #     IR completes the routing inside Traefik.
  component_service_urls = {
    for name, c in local.normalized_components :
    name => (
      c.kind == "external"
      ? "http://${c.service.name}.${c.service.namespace}.svc.cluster.local:${c.service.port}"
      : "http://${name}.${local.namespace}.svc.cluster.local:${c.port}"
    )
  }

  # Components that opted into HTTP BasicAuth (set `basic_auth: true` in
  # their yaml). One random password is generated per component and
  # exposed (sensitive) via `output.basic_auth_credentials`.
  basic_auth_components = {
    for name, c in local.normalized_components :
    name => c if try(c.basic_auth, false)
  }

  needs_db = anytrue([
    for _, c in local.normalized_components : try(c.db, false)
  ])

  db_name = replace(local.namespace, "-", "_")
  db_user = replace(local.namespace, "-", "_")
}

# Catch typos / missing component definitions at plan time.
check "routes_reference_known_components" {
  assert {
    condition = alltrue([
      for name in local._component_names : contains(keys(var.components), name)
    ])
    error_message = "project '${local.namespace}' has a route to an unknown component. Referenced components: ${jsonencode(local._component_names)}. Available components: ${jsonencode(keys(var.components))}. Add the missing config/components/<name>.yaml or fix the route target."
  }
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
  for_each = local.deployable_components

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
  security     = try(each.value.security, {})
}

# ── BasicAuth (per-component) ─────────────────────────────────────────────────
#
# Generates a random 20-char password for each component whose spec sets
# `basic_auth: true`, stores it as a Traefik-compatible htpasswd Secret
# (`admin:<bcrypt>`), and wires a Middleware that the component's
# IngressRoute consumes. Plaintext is exposed via the sensitive
# `basic_auth_credentials` output — retrieve with
# `terraform output -json basic_auth_credentials | jq`.

resource "random_password" "basic_auth" {
  for_each = local.basic_auth_components

  length  = 20
  special = false

  # Pin regeneration to the namespace+component identity so a provider
  # bump does not silently rotate a live dashboard password.
  keepers = {
    namespace = local.namespace
    component = each.key
  }
}

resource "kubernetes_secret_v1" "basic_auth" {
  for_each = local.basic_auth_components

  metadata {
    name      = "${each.key}-basic-auth"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    # Traefik's BasicAuth middleware expects htpasswd in the `users` key:
    # `<login>:<bcrypt_hash>`. random_password.bcrypt_hash is computed once
    # at creation and persisted, so plans are stable (unlike the global
    # `bcrypt()` function which re-salts on every invocation).
    users = "admin:${random_password.basic_auth[each.key].bcrypt_hash}"
  }
}

resource "kubectl_manifest" "basic_auth_middleware" {
  for_each = local.basic_auth_components

  depends_on = [kubernetes_secret_v1.basic_auth]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "${each.key}-basic-auth"
      namespace = local.namespace
    }
    spec = {
      basicAuth = {
        secret = "${each.key}-basic-auth"
      }
    }
  })
}

# ── IngressRoutes ─────────────────────────────────────────────────────────────
#
# One IngressRoute per component, carrying every route that points at it.
# Components without any route (`routes_by_component[name]` empty) get no
# IngressRoute — but the current model has none: a component is deployed
# only because at least one route targets it, so the list is always
# non-empty here.

resource "kubectl_manifest" "ingressroute" {
  for_each = local.routes_by_component

  depends_on = [module.component, kubectl_manifest.basic_auth_middleware]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = each.key
      namespace = local.namespace
    }
    spec = merge(
      {
        entryPoints = local.ir_entry_points[each.key]
        routes = [merge(
          {
            match    = join(" || ", [for d in each.value : "Host(`${d}`)"])
            kind     = "Rule"
            services = [local.ir_service_refs[each.key]]
          },
          contains(keys(local.basic_auth_components), each.key)
          ? { middlewares = [{ name = "${each.key}-basic-auth" }] }
          : {}
        )]
      },
      # `tls` only applies on the `websecure` entrypoint; omitting the
      # block on `web` keeps the CRD valid and avoids Traefik rejecting the
      # route with "cannot set TLS options on non-TLS entry point".
      contains(local.ir_entry_points[each.key], "websecure")
      ? { tls = { certResolver = "letsencrypt-production" } }
      : {}
    )
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

# Every fully-qualified hostname → which component/service it routes to.
# Consumed by the root `cloudflare.tf` to build the Cloudflare tunnel
# ingress rules and the per-host CNAME DNS records.
output "hostnames" {
  value = merge([
    for component, hosts in local.routes_by_component : {
      for host in hosts : host => {
        component = component
        service   = local.component_service_urls[component]
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

output "basic_auth_credentials" {
  sensitive   = true
  description = "HTTP BasicAuth credentials generated for every component in this project whose spec sets `basic_auth: true`. Keyed by component name; value is `{user, password}` in plaintext. Retrieve with: terraform output -json basic_auth_credentials | jq"
  value = {
    for name, _ in local.basic_auth_components :
    name => {
      user     = "admin"
      password = random_password.basic_auth[name].result
    }
  }
}
