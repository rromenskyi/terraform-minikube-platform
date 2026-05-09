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
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
  }
}


# Shared-service endpoints. All four are nullable: when the matching
# `services.<name>` flag in `config/platform.yaml` is off at the
# platform root, the corresponding module emits null, and any tenant
# component that asks for that service is caught by the preconditions
# below with a clear error message.


# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  namespace = var.project_config.namespace       # e.g. "phost-paseka-co-prod"
  domain    = var.project_config.name            # e.g. "paseka.co"
  env       = var.project_config.env             # e.g. "prod"
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
  # Four-step shallow merge:
  #   1. built-in default `kind`
  #   2. project-module fallbacks (`local.component_defaults`)
  #   3. the component yaml itself (`var.components[name]`)
  #   4. per-project overrides from the domain yaml
  #      (`project_config.components[name]`) — top-level keys here win
  #      over the same keys in the component yaml. Lists/nested maps
  #      are REPLACED wholesale (Terraform merge() is shallow), with
  #      one named exception below.
  #
  # `env_static` is specifically deep-merged: the operator's override
  # ADDS to (and wins per-key over) the component template's
  # `env_static`. Reason — `env_static` is the natural place to drop
  # per-tenant environment knobs (canonical URL, hostname-derived
  # OAuth callback, feature flags) without owning the whole envvar
  # surface area of a third-party chart. Without this exception, the
  # operator would have to copy every template env in to keep the
  # template working — an immediate footgun when chart upstreams
  # bump their env contract.
  normalized_components = {
    for name in local._component_names :
    name => merge(
      { kind = "deployment" },
      local.component_defaults,
      try(var.components[name], {}),
      try(var.project_config.components[name], {}),
      {
        env_static = merge(
          try(var.components[name].env_static, {}),
          try(var.project_config.components[name].env_static, {}),
        )
      },
    )
  }

  # `kind: deployment` (legacy/general containers) and `kind: app`
  # (first-party apps with optional Zitadel auto-provisioning) both
  # produce a Deployment + Service through `module.component`. The
  # difference is purely whether the project module also stands up
  # an OIDC client for them — see `app_components_with_oidc` below.
  deployable_components = {
    for name, c in local.normalized_components :
    name => c if c.kind == "deployment" || c.kind == "app"
  }

  external_components = {
    for name, c in local.normalized_components :
    name => c if c.kind == "external"
  }

  # Components that opted into Zitadel auto-provisioning (kind: app +
  # oidc.enabled: true). One Project + Application + Roles get
  # provisioned per entry, and the resulting client_id/secret/issuer
  # land in a per-component k8s Secret that the workload mounts as
  # env_from.
  app_components_with_oidc = {
    for name, c in local.normalized_components :
    name => c
    if c.kind == "app" && try(c.oidc.enabled, false)
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
  # Traefik v3 is strict about `port`: an integer is matched as a port
  # *number*, a string as a port *name*. We always want number lookup —
  # so every branch here emits a homogeneously-typed map (via a
  # conditional-filter trick on null-valued keys: `yamlencode` drops
  # keys whose value is `null`, giving us an optional-field effect
  # without Terraform collapsing the whole value to `map(string)`).
  ir_service_refs = {
    for name, c in local.normalized_components :
    name => {
      for k, v in {
        kind      = try(c.ingress_service.kind, null)
        name      = try(c.ingress_service.name, c.kind == "external" ? c.service.name : name)
        namespace = c.kind == "external" && try(c.ingress_service, null) == null ? c.service.namespace : null
        port      = try(c.ingress_service, null) != null ? null : (c.kind == "external" ? tonumber(c.service.port) : tonumber(c.port))
        # Upstream protocol Traefik uses to talk to the backend.
        # `h2c` (HTTP/2 cleartext) is required for components that
        # expose gRPC — Traefik's default is HTTP/1.1 which breaks
        # gRPC framing. Set `scheme: h2c` in the component yaml.
        scheme = try(c.scheme, null)
      } : k => v if v != null
    }
  }

  # Traefik entryPoints the IngressRoute answers on.
  #
  # Cloudflare Tunnel terminates TLS at the edge and forwards plain HTTP
  # to cloudflared → Traefik on the `web` entrypoint, so that is the
  # default. A component can override to `websecure` if it is reachable
  # by direct LAN/node-IP (outside the tunnel) and wants Let's Encrypt
  # termination via `letsencrypt-production`.
  ir_entry_points = {
    for name, c in local.normalized_components :
    name => try(c.entry_points, ["web"])
  }

  # URL cloudflared forwards this route's requests to.
  #
  # Single uniform target: Traefik's in-cluster Service. Traefik then
  # matches the IngressRoute (host + middlewares) and proxies to the
  # tenant workload or external Service. Keeping one hop through Traefik
  # means BasicAuth, rate-limit, strip-prefix middlewares — anything
  # declared on the IngressRoute — actually runs on every request
  # regardless of component kind. The previous direct-to-Service shortcut
  # bypassed all of that for `kind: deployment`.
  component_service_urls = {
    for name, _ in local.normalized_components :
    name => "http://traefik.ingress-controller.svc.cluster.local:80"
  }

  # Components that opted into HTTP BasicAuth (set `basic_auth: true` in
  # their yaml). One random password is generated per component and
  # exposed (sensitive) via `output.basic_auth_credentials`.
  basic_auth_components = {
    for name, c in local.normalized_components :
    name => c if try(c.basic_auth, false)
  }

  # Components that opt into the cluster-wide oauth2-proxy auth gate
  # (`auth: zitadel` in the component yaml). The IngressRoute attaches
  # the cross-namespace ForwardAuth middleware emitted by the
  # `oauth2-proxy` root module. Empty when no component asks for it,
  # OR when the operator left Zitadel off — the precondition below
  # rejects `auth: zitadel` on a Zitadel-less platform up front.
  zitadel_auth_components = {
    for name, c in local.normalized_components :
    name => c if try(c.auth, "") == "zitadel"
  }

  # Components that declare `env_random: [VAR_1, VAR_2, ...]` in their
  # yaml. Every listed env name gets a random 32-char value terraform
  # owns and persists in state, injected into the container via a
  # dedicated per-component Secret. Cheap replacement for
  # "bake a secret into the YAML" — the YAML stays public-safe.
  env_random_pairs = merge([
    for name, c in local.normalized_components : {
      for env_name in try(c.env_random, []) :
      "${name}/${env_name}" => { component = name, env_name = env_name }
    }
  ]...)

  env_random_components = distinct([for _, p in local.env_random_pairs : p.component])

  needs_db = anytrue([
    for _, c in local.normalized_components : try(c.db, false)
  ]) || try(var.shared_services.db, false)

  # `shared_services.postgres` accepts two shapes:
  #   - bool (legacy): `true` → emit one default DB+role+Secret named
  #     after the namespace (`<ns>` / `postgres-credentials`).
  #   - map (new): `{ enabled: <bool>, extra_databases: [<key>, ...] }` →
  #     `enabled` controls the legacy default DB independently from the
  #     extras list; each extra key gets its own DB / role / Secret
  #     (`<ns>_<key>` / `<key>-postgres-credentials`). Use when one
  #     chart-managed app needs more than one Postgres logical DB in
  #     the same tenant namespace (e.g. an app + its Synapse).
  _shared_pg_raw     = try(var.shared_services.postgres, false)
  _shared_pg_default = can(tobool(local._shared_pg_raw)) ? tobool(local._shared_pg_raw) : try(local._shared_pg_raw.enabled, false)
  _shared_pg_extras  = can(tobool(local._shared_pg_raw)) ? [] : try(local._shared_pg_raw.extra_databases, [])

  needs_postgres = anytrue([
    for _, c in local.normalized_components : try(c.postgres, false)
  ]) || local._shared_pg_default

  pg_default_instances = local.needs_postgres ? toset(["enabled"]) : toset([])
  pg_extra_databases   = toset(local._shared_pg_extras)

  needs_redis = anytrue([
    for _, c in local.normalized_components : try(c.redis, false)
  ]) || try(var.shared_services.redis, false)

  needs_ollama = anytrue([
    for _, c in local.normalized_components : try(c.ollama, false)
  ]) || try(var.shared_services.ollama, false)

  # Routed through `terraform-null-label` (same module already adopted
  # by chart_oidc + postgres extras) so naming rules are uniform across
  # the engine. The output `module.label.id` is `<namespace>` with
  # `_` delimiter (Postgres-identifier-safe) — exactly what the prior
  # `replace(local.namespace, "-", "_")` produced. Visible names are
  # unchanged for every existing tenant.
  #
  # `id_max_length = 63` is Postgres's `NAMEDATALEN - 1`. On overflow
  # null-label truncates to cap-9 chars + delimiter + 8-char sha256
  # suffix to keep uniqueness. Long namespaces no longer get silently
  # truncated by Postgres itself.
  db_name = module.pg_credentials_label.id
  db_user = module.pg_credentials_label.id

  # PostgreSQL default-DB naming uses the same identifier — DB and
  # role names are equal here on purpose (the module is opinionated:
  # one DB == one role per tenant for the legacy single-DB path).
  pg_database = module.pg_credentials_label.id
  pg_user     = module.pg_credentials_label.id

  # Redis ACL user names don't allow all characters. Namespace slugs
  # already fit the safe subset (lowercase + dash). Key prefix namespaces
  # every tenant's keyspace under `<namespace>:` so `GET whatever` in one
  # tenant can never collide with another.
  redis_user       = local.namespace
  redis_key_prefix = "${local.namespace}:"
}

# Project-tier label — the keystone for every per-feature label
# instance below. Chains off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`), so any tag the
# operator adds at the platform tier propagates here and downstream.
#
# `namespace = local.namespace` overrides the inherited
# `namespace = "platform"` from the root context — at this tier the
# k8s namespace IS the tenant identifier. `environment = local.env`
# specialises the inherited (empty) env. Other context fields
# (operator-added tags) inherit unchanged.
#
# Per-feature labels below pass `context = module.project_label.context`
# so they pick up the same tag set + can override only what they
# specifically need (delimiter, label_order, length cap).
module "project_label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context     = var.context
  namespace   = local.namespace
  environment = local.env
  name        = local.namespace
  tags = {
    "domain" = local.domain
  }
}

# Per-tenant Postgres / MySQL credential identifiers (DB + role
# names). Postgres-safe `_` delimiter and length cap
# (`NAMEDATALEN - 1 = 63`) match what `pg_extra_label` does for the
# `extra_databases` path so legacy and extras paths produce
# uniformly-shaped names.
#
# `replace(local.namespace, "-", "_")` is required because
# null-label's `delimiter` joins label components but does not
# transform character sets within a single component — the
# delimiter only matters when `label_order` has multiple entries.
# Output `id = "phost_<slug>_<env>"` is byte-for-byte identical to
# the prior inline `replace(...)`. Plan diff is zero for any
# existing tenant.
module "pg_credentials_label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context       = module.project_label.context
  name          = replace(local.namespace, "-", "_")
  delimiter     = "_"
  label_order   = ["name"]
  id_max_length = 63
}

# Catch typos / missing component definitions at plan time.
# A routed component is "known" if it has either a generic template
# at `config/components/<name>.yaml` OR an inline definition in this
# project's `envs.<env>.components.<name>` block.
check "routes_reference_known_components" {
  assert {
    condition = alltrue([
      for name in local._component_names :
      contains(keys(var.components), name) || contains(keys(try(var.project_config.components, {})), name)
    ])
    error_message = "project '${local.namespace}' has a route to an unknown component. Referenced components: ${jsonencode(local._component_names)}. Available templates: ${jsonencode(keys(var.components))}. Inline overrides: ${jsonencode(keys(try(var.project_config.components, {})))}. Add `config/components/<name>.yaml` OR an inline `envs.<env>.components.<name>` block in the domain yaml."
  }
}

# Shared-service preconditions: a component asks for MySQL/Redis/Ollama
# only if the operator flipped the matching `services.<name>` toggle in
# `config/platform.yaml` on. Check blocks warn at plan time; the
# resources that actually consume these inputs (`kubernetes_job_v1`,
# `kubernetes_secret_v1`) will then fail with a cleaner error if the
# warning is ignored.
check "mysql_enabled_when_needed" {
  assert {
    condition     = !local.needs_db || var.mysql_host != null
    error_message = "project '${local.namespace}' has a component with `db: true` but `services.mysql` is disabled in config/platform.yaml. Either enable MySQL or drop `db: true` from the component spec."
  }
}

check "postgres_enabled_when_needed" {
  assert {
    condition     = !local.needs_postgres || var.postgres_host != null
    error_message = "project '${local.namespace}' has a component with `postgres: true` but `services.postgres` is disabled in config/platform.yaml. Either enable PostgreSQL or drop `postgres: true` from the component spec."
  }
}

check "redis_enabled_when_needed" {
  assert {
    condition     = !local.needs_redis || var.redis_host != null
    error_message = "project '${local.namespace}' has a component with `redis: true` but `services.redis` is disabled in config/platform.yaml. Either enable Redis or drop `redis: true` from the component spec."
  }
}

check "ollama_enabled_when_needed" {
  assert {
    condition     = !local.needs_ollama || var.ollama_url != null
    error_message = "project '${local.namespace}' has a component with `ollama: true` but `services.ollama` is disabled in config/platform.yaml. Either enable Ollama or drop `ollama: true` from the component spec."
  }
}

check "oauth2_proxy_available_when_zitadel_auth_used" {
  assert {
    condition     = length(local.zitadel_auth_components) == 0 || (var.oauth2_proxy_middlewares != null && length(var.oauth2_proxy_middlewares) > 0)
    error_message = "project '${local.namespace}' has at least one component with `auth: zitadel` (${join(", ", keys(local.zitadel_auth_components))}) but the cluster-wide oauth2-proxy is not deployed — that gate is gated on `services.zitadel.enabled`. Either turn Zitadel on, or drop the `auth: zitadel` knob."
  }
}

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project"                      = local.domain
      "environment"                  = local.env
    })
  }
}

# ── Resource Quota ────────────────────────────────────────────────────────────

resource "kubernetes_resource_quota_v1" "limits" {
  metadata {
    name      = "limits"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
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
  for_each = local.needs_db ? toset(["enabled"]) : toset([])
  length   = 24
  special  = false
}

# Provisions the DB and user inside the shared MySQL via a Kubernetes Job.
# The Job runs a mysql client container in-cluster — no dependency on local
# kubectl or shell escaping. Database is intentionally NOT dropped on destroy
# to preserve data.
resource "kubernetes_job_v1" "mysql_setup" {
  for_each = local.needs_db ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "db-setup-${local.namespace}"
    namespace = var.mysql_namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    })
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

          # Tiny one-shot — runs a few DDL statements and exits. Explicit
          # resources are required because the platform namespace's
          # ResourceQuota rejects pods without `limits` and `requests`.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          command = [
            "sh", "-c",
            join("", [
              "mysql -h ${var.mysql_host} -uroot ",
              "-p\"$MYSQL_ROOT_PASSWORD\" -e \"",
              "CREATE DATABASE IF NOT EXISTS \\`${local.db_name}\\`;",
              "CREATE USER IF NOT EXISTS '${local.db_user}'@'%' ",
              "IDENTIFIED BY '${values(random_password.db)[0].result}';",
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
  for_each = local.needs_db ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_job_v1.mysql_setup]

  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    DB_HOST = var.mysql_host
    DB_PORT = "3306"
    DB_NAME = local.db_name
    DB_USER = local.db_user
    DB_PASS = values(random_password.db)[0].result
  }
}

# ── PostgreSQL: per-namespace database + user (only when needed) ──────────────

resource "random_password" "postgres" {
  for_each = local.pg_default_instances

  length  = 24
  special = false
}

# Provisions the DB and user via a Kubernetes Job that runs psql
# in-cluster. Database is NOT dropped on destroy — data preservation
# matches the MySQL behaviour.
resource "kubernetes_job_v1" "postgres_setup" {
  for_each = local.pg_default_instances

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "postgres-setup-${local.namespace}"
    namespace = var.postgres_namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "postgres-setup-${local.namespace}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "postgres-setup"
          image = "postgres:16-alpine"

          env_from {
            secret_ref {
              name = var.postgres_superuser_secret
            }
          }

          # `PGPASSWORD` → picked up by psql automatically. `POSTGRES_PASSWORD`
          # is the key emitted by the postgres-superuser Secret in the platform
          # module; aliased here so both names resolve to the same value.
          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          # Tiny one-shot — see the mysql-setup container for the reasoning.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          # `CREATE DATABASE` / `CREATE ROLE` are not idempotent in vanilla SQL.
          # The DO-blocks below noop when the role or db already exists so
          # re-applies are safe (tenant DB survives terraform destroy → re-apply).
          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.pg_database}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${local.pg_database}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.pg_user}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${local.pg_user}\\\" WITH LOGIN PASSWORD '${values(random_password.postgres)[0].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${local.pg_user}\\\" WITH PASSWORD '${values(random_password.postgres)[0].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${local.pg_database}\\\" TO \\\"${local.pg_user}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${local.pg_database} -c \"GRANT ALL ON SCHEMA public TO \\\"${local.pg_user}\\\"\"",
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

resource "kubernetes_secret_v1" "postgres_credentials" {
  for_each = local.pg_default_instances

  depends_on = [kubernetes_job_v1.postgres_setup]

  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    PG_HOST      = var.postgres_host
    PG_PORT      = "5432"
    PG_DATABASE  = local.pg_database
    PG_USER      = local.pg_user
    PG_PASSWORD  = values(random_password.postgres)[0].result
    DATABASE_URL = "postgres://${local.pg_user}:${values(random_password.postgres)[0].result}@${var.postgres_host}:5432/${local.pg_database}"
  }
}

# ── PostgreSQL: per-namespace EXTRA databases (multi-DB tenants) ──────────────
#
# Triggered by `shared_services.postgres.extra_databases: [<key>, ...]`
# in the domain yaml. Each key materialises an independent
# DB + role + Secret in this namespace, named `<ns>_<key>` (DB and
# role) and `<key>-postgres-credentials` (Secret). The role gets the
# same `GRANT ALL ON SCHEMA public` we hand out to the default DB —
# chart-side schema migrations own the ddl.
#
# Use case: one chart-managed app needs more than one logical
# Postgres database in the same tenant namespace (e.g. mm-core +
# Synapse share a tenant ns but each owns its own schema). The
# default DB controlled by `enabled` is independent — set
# `enabled: false` if every database the chart needs is named.
#
# Naming uses underscore separators because Postgres identifiers
# can't carry dashes without quoting; same convention as the default
# `pg_database` / `pg_user` already use.

# Composes the per-extra-database identifier (DB name + role name)
# through `terraform-null-label`. Same shape as the chart_oidc adoption:
# operator-readable, length-capped, and tagged consistently across Job
# + Secret labels.
#
# `delimiter = "_"` because Postgres identifiers must be quoted to use
# dashes — staying ASCII-safe lets every downstream `psql` interaction
# skip the extra quoting layer. `namespace` is already env-encoded
# (`phost-<slug>-<env>` → `phost_<slug>_<env>`), so `label_order =
# ["namespace", "name"]` skips the env attribute that chart_oidc's
# label adds — would just duplicate.
#
# `id_max_length = 63` is Postgres's identifier limit (`NAMEDATALEN -
# 1`); on overflow null-label truncates to cap-9 chars + delimiter +
# 8-char sha256 suffix to keep uniqueness. Long namespace + long key
# combos no longer silently get truncated by Postgres itself.
module "pg_extra_label" {
  for_each = local.pg_extra_databases

  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context       = module.project_label.context
  namespace     = replace(local.namespace, "-", "_") # "phost_<slug>_<env>" — overrides parent dashed form
  name          = each.key                           # the extra-database key
  delimiter     = "_"
  label_order   = ["namespace", "name"]
  id_max_length = 63
  tags = {
    "app.kubernetes.io/component" = "postgres-extra-db"
    "extra-database"              = each.key
  }
}

resource "random_password" "postgres_extra" {
  for_each = local.pg_extra_databases

  length  = 24
  special = false
}

resource "kubernetes_job_v1" "postgres_setup_extra" {
  for_each = local.pg_extra_databases

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "postgres-setup-${local.namespace}-${each.key}"
    namespace = var.postgres_namespace
    labels    = module.pg_extra_label[each.key].tags
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "postgres-setup-${local.namespace}-${each.key}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "postgres-setup"
          image = "postgres:16-alpine"

          env_from {
            secret_ref {
              name = var.postgres_superuser_secret
            }
          }

          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${module.pg_extra_label[each.key].id}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${module.pg_extra_label[each.key].id}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${module.pg_extra_label[each.key].id}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${module.pg_extra_label[each.key].id}\\\" WITH LOGIN PASSWORD '${random_password.postgres_extra[each.key].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${module.pg_extra_label[each.key].id}\\\" WITH PASSWORD '${random_password.postgres_extra[each.key].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${module.pg_extra_label[each.key].id}\\\" TO \\\"${module.pg_extra_label[each.key].id}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${module.pg_extra_label[each.key].id} -c \"GRANT ALL ON SCHEMA public TO \\\"${module.pg_extra_label[each.key].id}\\\"\"",
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

resource "kubernetes_secret_v1" "postgres_credentials_extra" {
  for_each = local.pg_extra_databases

  depends_on = [kubernetes_job_v1.postgres_setup_extra]

  metadata {
    name      = "${each.key}-postgres-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.pg_extra_label[each.key].tags
  }

  data = {
    PG_HOST      = var.postgres_host
    PG_PORT      = "5432"
    PG_DATABASE  = module.pg_extra_label[each.key].id
    PG_USER      = module.pg_extra_label[each.key].id
    PG_PASSWORD  = random_password.postgres_extra[each.key].result
    DATABASE_URL = "postgres://${module.pg_extra_label[each.key].id}:${random_password.postgres_extra[each.key].result}@${var.postgres_host}:5432/${module.pg_extra_label[each.key].id}"
  }
}

# ── Redis: per-namespace ACL user + key-prefix (only when needed) ─────────────

resource "random_password" "redis" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])
  length   = 24
  special  = false
}

# Creates an ACL user on the shared Redis limited to the tenant's key
# prefix. `resetkeys ~<ns>:*` wipes any previous key permissions then
# grants only `<ns>:*` — two tenants can't read or overwrite each
# other's keys. `+@all -@dangerous` gives every command group except
# destructive ones (FLUSHDB, FLUSHALL, CONFIG, SHUTDOWN, …).
#
# The user name is NOT deleted on terraform destroy — same policy as
# MySQL, so data isn't lost if a project is removed and re-added.
resource "kubernetes_job_v1" "redis_setup" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    # Job name carries the Valkey helm revision so a chart upgrade
    # (which can switch the Sentinel master and discard the
    # previously-applied tenant ACL) renames the Job, Terraform
    # replaces it, and the ACL is re-applied against the post-upgrade
    # master. Without this, tenant pods get `WRONGPASS` after every
    # redis chart upgrade until the operator manually `terraform taint`s
    # the Job — historic flake source documented 2026-05-09.
    name      = "redis-setup-${local.namespace}-rev${var.redis_helm_revision}"
    namespace = var.redis_namespace
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = local.namespace
    })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = {
          job = "redis-setup-${local.namespace}-rev${var.redis_helm_revision}"
        }
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "redis-setup"
          image = "redis:7-alpine"

          env_from {
            secret_ref {
              name = var.redis_default_secret
            }
          }

          # Tiny one-shot — see the mysql-setup container for the reasoning.
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }

          # The `>` prefix on the password is Redis ACL syntax ("add this
          # password to the user"), *not* shell redirection — escape it so
          # `sh -c` does not strip the password into a stray output file
          # and leave the ACL user without any credentials.
          #
          # The trailing `ACL SAVE` persists the new user to Redis's
          # aclfile (/data/users.acl on the shared PV). Without it the
          # user lives only in-memory and vanishes on the next redis-0
          # restart — the exact regression this fix addresses. `SETUSER`
          # and `SAVE` run as two separate redis-cli invocations so the
          # shell `&&` short-circuits SAVE if SETUSER fails.
          command = [
            "sh", "-c",
            "${join(" ", [
              "redis-cli -h ${var.redis_host} -a \"$REDIS_PASSWORD\"",
              "ACL SETUSER ${local.redis_user}",
              "on",
              "\\>${values(random_password.redis)[0].result}",
              "resetkeys",
              "~${local.redis_key_prefix}*",
              # Reset + scope pub/sub channels to the same prefix.
              # Default `resetchannels` denies every channel; without
              # this the user holds `+@pubsub` commands but can't
              # subscribe to anything (NOPERM at SUBSCRIBE time).
              # Two patterns: `<ns>:*` covers the keyspace-style
              # channel naming (e.g. `<ns>:notifications`); `<ns>::*`
              # covers the double-colon namespace separator some
              # apps use (e.g. `<ns>::dialog_actions`). Both whitelisted
              # so either convention works without per-app schema.
              "resetchannels",
              # `&` is a literal Redis ACL channel-pattern prefix; in
              # `sh -c` it's also the background-job operator. Escape
              # so the shell passes `&pattern*` through verbatim
              # instead of interpreting as `&` + glob.
              "\\&${local.redis_key_prefix}*",
              "\\&${local.namespace}::*",
              "+@all",
              "-@dangerous",
              # Object-cache plugins (WP redis-cache, Drupal Redis, …)
              # use INFO for health / server-version detection and
              # FLUSHDB to drop their tenant keyspace on admin action.
              # Both live in `@dangerous` in Redis 7's category tree, so
              # re-granting them explicitly is safer and cheaper than
              # removing the whole `-@dangerous` ceiling.
              "+INFO",
              "+FLUSHDB",
            ])} && redis-cli -h ${var.redis_host} -a \"$REDIS_PASSWORD\" ACL SAVE"
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

resource "kubernetes_secret_v1" "redis_credentials" {
  for_each = local.needs_redis ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_job_v1.redis_setup]

  metadata {
    name      = "redis-credentials"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    REDIS_HOST       = var.redis_host
    REDIS_PORT       = "6379"
    REDIS_USER       = local.redis_user
    REDIS_PASSWORD   = values(random_password.redis)[0].result
    REDIS_KEY_PREFIX = local.redis_key_prefix
  }
}

# ── Ollama: no per-tenant credentials, just the shared endpoint URL ───────────
#
# Ollama has no native auth — every component on the platform shares the
# same instance and addresses it by plain URL. There's nothing tenant-
# specific to provision, so there's no setup Job; this Secret is a
# namespace-scoped convenience so `env_from.secret_ref` in
# modules/component works the same way as for `db_secret_name`.

resource "kubernetes_secret_v1" "ollama_endpoint" {
  for_each = local.needs_ollama ? toset(["enabled"]) : toset([])

  metadata {
    name      = "ollama-endpoint"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  # Different Ollama clients read different env names: the official
  # `ollama` CLI and the Python SDK want `OLLAMA_HOST`, Open WebUI
  # insists on `OLLAMA_BASE_URL`, some LangChain integrations use
  # `OLLAMA_API_BASE`. Emit them all pointing at the same URL so any
  # component can `ollama: true` without caring which client it uses.
  data = {
    OLLAMA_HOST     = var.ollama_url
    OLLAMA_BASE_URL = var.ollama_url
    OLLAMA_API_BASE = var.ollama_url
  }
}

# ── Operator-defined Secrets (per-env `secrets:` block) ───────────────────────
#
# Two modes per entry, picked by whether the same name shows up as a
# top-level key in `var.operator_secret_values`:
#
#   1. Random shared (default — `var.operator_secret_values[<name>]`
#      not set). Engine generates ONE `random_password` per entry
#      and writes it to every listed key. Fits app-key style use
#      cases where a chart's `envFrom` exposes the same shared
#      bytes under multiple env names.
#
#   2. Literal (`var.operator_secret_values[<name>]` present). Engine
#      writes the supplied k:v map straight into the Secret's data.
#      Plan-time check below rejects partial coverage so a forgotten
#      key surfaces before apply, not at first pod boot. Fits
#      operator-supplied credentials the engine cannot synthesize:
#      third-party storage / OIDC client / vendor API keys.
#
# `random_password.operator_secret` is generated for every entry
# regardless of mode — cheap, kept in state, and lets an operator
# flip an entry from literal to random by deleting its
# `var.operator_secret_values` key without re-planning the random.

check "operator_secret_values_cover_yaml_keys" {
  assert {
    condition = alltrue([
      for name, vals in var.operator_secret_values :
      !contains(keys(var.secrets), name)
      || alltrue([
        for k in try(var.secrets[name].keys, []) :
        contains(keys(vals), k)
      ])
    ])
    error_message = "var.operator_secret_values supplies an entry whose inner map is missing a key declared under `secrets.<name>.keys` in the domain yaml. Project '${local.namespace}'. Each literal-mode Secret must cover every yaml-listed key. Add the missing key to terraform.tfvars or remove it from the domain yaml."
  }
}

resource "random_password" "operator_secret" {
  for_each = var.secrets

  length  = try(each.value.length, 48)
  special = false
}

resource "kubernetes_secret_v1" "operator_secret" {
  for_each = var.secrets

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = merge(module.project_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/part-of"    = local.namespace
    })
  }

  data = (
    contains(keys(var.operator_secret_values), each.key)
    ? {
      for k in try(each.value.keys, []) :
      k => var.operator_secret_values[each.key][k]
    }
    : {
      for k in try(each.value.keys, []) :
      k => random_password.operator_secret[each.key].result
    }
  )
}

# ── Zitadel auto-provisioning for chart-deployed apps ────────────────────────
#
# Counterpart of the `kind: app` machinery below — but for charts the
# engine doesn't render itself (Argo CD-managed Helm charts in this
# project's namespace). Operator declares
# `chart_oidc_apps:<secret-name>` in the domain yaml; engine spins up
# one Zitadel Project + OIDC Application per entry and writes the
# four standard keys (issuer / client_id / client_secret / auth
# secret) into a `kubernetes_secret_v1` of the matching name in the
# project namespace. The chart's `envFrom: secretRef` then picks
# them up — no operator-side `kubectl create secret`, no OIDC
# values committed in plain text.

check "zitadel_enabled_when_chart_oidc_used" {
  assert {
    condition     = length(var.chart_oidc_apps) == 0 || var.zitadel_issuer_url != null
    error_message = "project '${local.namespace}' declares `chart_oidc_apps:` entries (${join(", ", keys(var.chart_oidc_apps))}) but `services.zitadel.enabled` is false. Either flip Zitadel on in `config/platform.yaml` or remove the chart_oidc_apps block."
  }
}

check "zitadel_provider_authenticated_when_chart_oidc_used" {
  assert {
    condition     = length(var.chart_oidc_apps) == 0 || var.zitadel_provider_authenticated
    error_message = "project '${local.namespace}' declares `chart_oidc_apps:` entries but `var.zitadel_pat` is empty — the Zitadel TF provider can't authenticate, so `zitadel_application_oidc` resources would fail at apply time. Set `TF_VAR_zitadel_pat` from a Zitadel IAM_OWNER PAT and re-run."
  }
}

# Naming for chart_oidc_apps entries.
#
# The yaml key (e.g. `sipmesh-frontend-oidc`) is descriptive of the
# Secret it produces (k8s Secret carrying `AUTH_ZITADEL_*`), but
# defaulting the Zitadel project + app name to the same string
# leaves operators reading the Zitadel UI unable to tell which
# environment they're looking at — `sipmesh-frontend-oidc` could be
# dev, prod, staging.
#
# Solution: route naming through `terraform-null-label` so the
# Zitadel project + app name auto-include the env (`sipmesh-frontend
# -dev`), while the k8s Secret name keeps the descriptive `-oidc`
# suffix the chart's `envFrom` references. Operators can override
# every output via explicit `project_name` / `app_name` /
# `secret_name` fields per entry — `try(each.value.X, default)`
# preserves the override-wins semantics.
#
# `trimsuffix(each.key, "-oidc")` strips the operator's descriptive
# Secret-naming convention before composing the project / app id —
# the engine's strong opinion is that yaml keys SHOULD end in
# `-oidc` (matches what the pod's envFrom references) but the
# Zitadel-side names SHOULD NOT (operators read those in the
# Zitadel console where `-oidc` is just noise).
module "chart_oidc_label" {
  for_each = var.chart_oidc_apps

  source  = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"
  context = module.project_label.context
  name    = trimsuffix(each.key, "-oidc")
  # Explicit `label_order` shrinks the id to `<name>-<attributes>`
  # so the Zitadel project name stays the operator's chosen
  # `<key-without-oidc-suffix>-<env>` shape. Without this override
  # the inherited default `["namespace", "environment", "name",
  # "attributes"]` from `module.project_label.context` would prefix
  # the id with the tenant namespace + env, renaming every existing
  # Zitadel project — destructive.
  label_order = ["name", "attributes"]
  attributes  = [local.env]
}

module "chart_oidc" {
  for_each = var.chart_oidc_apps

  source = "../zitadel-app"

  org_id           = var.zitadel_org_id
  project_name     = try(each.value.project_name, module.chart_oidc_label[each.key].id)
  app_name         = try(each.value.app_name, module.chart_oidc_label[each.key].id)
  issuer_url       = var.zitadel_issuer_url
  redirect_uris    = try(each.value.redirect_uris, [])
  post_logout_uris = try(each.value.post_logout_uris, [])
  dev_mode         = try(each.value.dev_mode, false)
  roles            = try(each.value.roles, [])

  secret_namespace = kubernetes_namespace_v1.this.metadata[0].name
  secret_name      = try(each.value.secret_name, each.key)
  secret_formats   = try(each.value.secret_formats, ["auth_js"])
}

# ── Zitadel auto-provisioning for `kind: app` components ─────────────────────
#
# One Project + Application + Roles + k8s Secret per opted-in app.
# Project name defaults to the component name (v1: one project per
# app); roles default to `[platform_admin, tenant_admin, user]` so a
# bare `oidc.enabled: true` already buys a usable role tree. Override
# both via the component yaml — see any `kind: app` example for the
# worked shape.

check "zitadel_issuer_set_when_app_oidc_used" {
  assert {
    condition     = length(local.app_components_with_oidc) == 0 || var.zitadel_issuer_url != null
    error_message = "project '${local.namespace}' has at least one `kind: app` component with `oidc.enabled: true` (${join(", ", keys(local.app_components_with_oidc))}) but `services.zitadel.enabled` is false. Either flip Zitadel on in `config/platform.yaml` or remove the oidc block."
  }
}

check "zitadel_pat_set_when_app_oidc_used" {
  assert {
    condition     = length(local.app_components_with_oidc) == 0 || var.zitadel_provider_authenticated
    error_message = "project '${local.namespace}' has `kind: app` components with `oidc.enabled: true` (${join(", ", keys(local.app_components_with_oidc))}) but `TF_VAR_zitadel_pat` is empty. Bootstrap the PAT once: `kubectl get secret zitadel-tf-pat -n platform -o jsonpath='{.data.access_token}' | base64 -d`, then paste it into `.env` as `TF_VAR_zitadel_pat=...`. See operating.md → 'Zitadel PAT bootstrap'."
  }
}

module "zitadel_app" {
  for_each = local.app_components_with_oidc

  source = "../zitadel-app"

  org_id       = var.zitadel_org_id
  project_name = try(each.value.oidc.project, each.key)
  app_name     = each.key

  issuer_url = var.zitadel_issuer_url

  # Build prod-style redirect URIs from the hostnames Traefik routes
  # to this component crossed with the operator-supplied paths. Local
  # `http://localhost:5173/...` URIs are intentionally NOT auto-added
  # — wire those by hand on a separate dev-mode application in the
  # Zitadel UI when iterating locally.
  redirect_uris = flatten([
    for host in local.routes_by_component[each.key] : [
      for path in try(each.value.oidc.redirect_paths, ["/auth/callback/zitadel"]) :
      "https://${host}${path}"
    ]
  ])

  post_logout_uris = flatten([
    for host in local.routes_by_component[each.key] : [
      for path in try(each.value.oidc.post_logout_paths, ["/"]) :
      "https://${host}${path}"
    ]
  ])

  grant_types    = try(each.value.oidc.grant_types, ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"])
  response_types = try(each.value.oidc.response_types, ["OIDC_RESPONSE_TYPE_CODE"])
  app_type       = try(each.value.oidc.app_type, "OIDC_APP_TYPE_WEB")
  auth_method    = try(each.value.oidc.auth_method, "OIDC_AUTH_METHOD_TYPE_BASIC")
  dev_mode       = try(each.value.oidc.dev_mode, false)

  roles = try(each.value.oidc.roles, [
    { key = "platform_admin", display_name = "Platform Admin", group = "" },
    { key = "tenant_admin", display_name = "Tenant Admin", group = "" },
    { key = "user", display_name = "User", group = "" },
  ])

  secret_namespace = kubernetes_namespace_v1.this.metadata[0].name
  secret_name      = "${each.key}-oidc"
}

# ── Components ────────────────────────────────────────────────────────────────

module "component" {
  for_each = local.deployable_components

  source = "../component"

  name              = each.key
  namespace         = kubernetes_namespace_v1.this.metadata[0].name
  image             = each.value.image
  image_pull_policy = try(each.value.image_pull_policy, null)
  port              = each.value.port
  replicas          = each.value.replicas
  resources         = each.value.resources

  health_path      = try(each.value.health_path, "/")
  storage          = try(each.value.storage, [])
  volume_base_path = var.volume_base_path

  # Optional git-sync sidecar — see modules/component variable
  # for the schema. Component yaml shape:
  #   git_sync:
  #     repo:                  git@github.com:org/repo.git
  #     branch:                main
  #     period_seconds:        60
  #     ssh_key_secret_name:   <pre-created Secret in this ns>
  #     mount:                 /usr/share/nginx/html
  git_sync = try(each.value.git_sync, null)

  db_env_mapping = try(each.value.env, {})
  db_secret_name = try(each.value.db, false) && local.needs_db ? (
    values(kubernetes_secret_v1.db_credentials)[0].metadata[0].name
  ) : null

  postgres_secret_name = try(each.value.postgres, false) && local.needs_postgres ? (
    values(kubernetes_secret_v1.postgres_credentials)[0].metadata[0].name
  ) : null

  redis_secret_name = try(each.value.redis, false) && local.needs_redis ? (
    values(kubernetes_secret_v1.redis_credentials)[0].metadata[0].name
  ) : null

  ollama_secret_name = try(each.value.ollama, false) && local.needs_ollama ? (
    values(kubernetes_secret_v1.ollama_endpoint)[0].metadata[0].name
  ) : null

  # OIDC Secret wiring — two ways the component can opt in:
  #
  #   1. `kind: app` + `oidc.enabled: true` — engine auto-creates
  #      a per-app Zitadel Project + OIDC Application via the
  #      `module.zitadel_app[<component>]` block above. The standard
  #      path for first-party apps the engine itself owns.
  #
  #   2. Any kind, with `oidc_secret_ref: <key>` pointing at a
  #      `chart_oidc_apps` entry — engine reuses an OIDC client
  #      defined at project scope. The path for third-party charts
  #      (Open WebUI, Grafana) where the env-name convention is
  #      controlled per-entry via `chart_oidc_apps.<key>.secret_formats`.
  #
  # When neither path applies, `oidc_secret_name` stays null and the
  # component starts without OAuth env (the chart's own degrade
  # behaviour decides whether anonymous access works or sign-in is
  # disabled).
  oidc_secret_name = (
    contains(keys(local.app_components_with_oidc), each.key)
    ? module.zitadel_app[each.key].secret_name
    : (
      try(each.value.oidc_secret_ref, null) != null
      && contains(keys(var.chart_oidc_apps), try(each.value.oidc_secret_ref, ""))
      ? module.chart_oidc[each.value.oidc_secret_ref].secret_name
      : null
    )
  )

  # Drive a pod rollout whenever the OIDC Secret rotates. K8s doesn't
  # do this on its own for envFrom-sourced env vars — see the
  # `pod_annotations` var in modules/component for the why.
  pod_annotations = (
    contains(keys(local.app_components_with_oidc), each.key)
    ? { "checksum/oidc" = module.zitadel_app[each.key].secret_checksum }
    : (
      try(each.value.oidc_secret_ref, null) != null
      && contains(keys(var.chart_oidc_apps), try(each.value.oidc_secret_ref, ""))
      ? { "checksum/oidc" = module.chart_oidc[each.value.oidc_secret_ref].secret_checksum }
      : {}
    )
  )

  static_env = try(each.value.env_static, {})

  random_env_secret_name = contains(local.env_random_components, each.key) ? (
    kubernetes_secret_v1.env_random[each.key].metadata[0].name
  ) : null
  env_random_keys = try(each.value.env_random, [])

  config_files = try(each.value.config_files, {})
  security     = try(each.value.security, {})
  sidecars     = try(each.value.sidecars, {})

  cluster_role_rules = try(each.value.cluster_role_rules, [])

  # Pod placement: passed through verbatim from per-component yaml.
  # Empty defaults preserve prior scheduling behaviour. See README
  # "Pod placement" for the supported keys (`node_selector:`,
  # `tolerations:`, `affinity:`) and the documented k8s schema each
  # mirrors.
  node_selector = try(each.value.node_selector, {})
  tolerations   = try(each.value.tolerations, [])
  affinity      = try(each.value.affinity, {})
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
    labels    = module.project_label.tags
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
      labels    = module.project_label.tags
    }
    spec = {
      basicAuth = {
        secret = "${each.key}-basic-auth"
      }
    }
  })
}

# ── env_random: per-component Secret with random values ──────────────────────
#
# For every `env_random: [VAR1, VAR2]` declaration in a component's yaml,
# generate one random_password per VAR and expose them all together in a
# namespace-scoped Secret named `<component>-random-env`. The component's
# container gets the Secret via `env_from` so every listed VAR appears as
# a plain env var, owning a value terraform persists across applies.

resource "random_password" "env_random" {
  for_each = local.env_random_pairs

  length  = 32
  special = false

  keepers = {
    namespace = local.namespace
    component = each.value.component
    env_name  = each.value.env_name
  }
}

resource "kubernetes_secret_v1" "env_random" {
  for_each = toset(local.env_random_components)

  metadata {
    name      = "${each.key}-random-env"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = module.project_label.tags
  }

  data = {
    for pair_key, p in local.env_random_pairs :
    p.env_name => random_password.env_random[pair_key].result
    if p.component == each.key
  }
}

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

check "argocd_bootstraps_require_argocd_ns" {
  assert {
    condition     = length(var.argocd_bootstraps) == 0 || var.argocd_namespace != ""
    error_message = "project '${local.namespace}' declares `argocd_bootstraps:` entries but `argocd_namespace` is empty. Enable `services.argocd.enabled = true` in `config/platform.yaml` and re-apply."
  }
}

check "argocd_hostnames_node_ip_set_when_no_tunnel" {
  assert {
    condition = alltrue([
      for _, h in var.argocd_hostnames :
      try(h.cf_tunnel, true) || try(h.node_ip, "") != ""
    ])
    error_message = "every `argocd_hostnames` entry with `cf_tunnel: false` must set `node_ip:` to the node's real public IP — TF emits an unproxied A record there, bypassing the Cloudflare Tunnel. Project '${local.namespace}'."
  }
}

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

      destinations = [
        # Workload destination — every chart-rendered resource the
        # sub-Applications spawn lands here.
        {
          server    = "https://kubernetes.default.svc"
          namespace = local.namespace
        },
        # Argo CD's own namespace — App-of-Apps materialises sub-
        # Application CRDs here. Without this entry the bootstrap
        # Application fails its own destination check ("destination
        # server ... and namespace 'argocd' do not match allowed
        # destinations") and never even reaches sync.
        {
          server    = "https://kubernetes.default.svc"
          namespace = var.argocd_namespace
        },
      ]

      namespaceResourceWhitelist = [
        { group = "*", kind = "*" },
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

  depends_on = [kubectl_manifest.argocd_app_project]

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
      project = local.namespace

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
      labels    = module.project_label.tags
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
          # Compose the middleware list from three sources:
          #   - `basic_auth: true` (per-component, in-namespace middleware)
          #   - `auth: zitadel` (cross-namespace forward-auth → oauth2-
          #     proxy in `ingress-controller`)
          #   - the platform-wide `errors` middleware that swaps
          #     Traefik's default `no available server` body for the
          #     branded fallback page when an IngressRoute's backend
          #     has zero ready endpoints. Always last in the chain so
          #     it only fires for upstream errors after auth has run.
          # Order matters — Traefik applies middlewares head-first.
          length(concat(
            contains(keys(local.basic_auth_components), each.key) ? [{ name = "${each.key}-basic-auth" }] : [],
            contains(keys(local.zitadel_auth_components), each.key) ? var.oauth2_proxy_middlewares : [],
            var.fallback_errors_middleware == null ? [] : [var.fallback_errors_middleware],
          )) > 0
          ? {
            middlewares = concat(
              contains(keys(local.basic_auth_components), each.key) ? [{ name = "${each.key}-basic-auth" }] : [],
              contains(keys(local.zitadel_auth_components), each.key) ? var.oauth2_proxy_middlewares : [],
              var.fallback_errors_middleware == null ? [] : [var.fallback_errors_middleware],
            )
          }
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
