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
  vault_auth_ref = var.vault_tenant_role != "" ? "vault-tenant" : ""
  namespace      = var.project_config.namespace       # e.g. "phost-example-com-prod"
  domain         = var.project_config.name            # e.g. "example.com"
  env            = var.project_config.env             # e.g. "prod"
  routes         = try(var.project_config.routes, {}) # { "": web, www: web, api: whoami2, "/api": api }

  # A route key is `<host-prefix>` (the whole host) or
  # `<host-prefix>/<path>` (only that path subtree of the host):
  # `"/api"` = <domain>/api/*, `"www/api"` = www.<domain>/api/*. Keys
  # without a `/` parse exactly as before. The path is normalised to a
  # leading `/` and no trailing `/`, and is NOT stripped before the
  # request reaches the workload — the service owns its full URL space.
  route_entries = [
    for key, target in local.routes : {
      component = target
      host      = split("/", key)[0] == "" ? local.domain : "${split("/", key)[0]}.${local.domain}"
      path      = strcontains(key, "/") ? trimsuffix("/${join("/", slice(split("/", key), 1, length(split("/", key))))}", "/") : null
    }
  ]

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
  #
  # Whole-host routes only; path-scoped routes live in
  # `path_routes_by_component`, and `hosts_by_component` is the union.
  routes_by_component = {
    for component in local._component_names :
    component => [for r in local.route_entries : r.host if r.component == component && r.path == null]
  }
  path_routes_by_component = {
    for component in local._component_names :
    component => [for r in local.route_entries : r if r.component == component && r.path != null]
  }
  hosts_by_component = {
    for component in local._component_names :
    component => distinct([for r in local.route_entries : r.host if r.component == component])
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

  # Middleware chain per component, shared by its whole-host and its
  # path-scoped IngressRoute rules. Three sources:
  #   - `basic_auth: true` (per-component, in-namespace middleware)
  #   - `auth: zitadel` (cross-namespace forward-auth → oauth2-proxy in
  #     `ingress-controller`)
  #   - the platform-wide `errors` middleware that swaps Traefik's default
  #     `no available server` body for the branded fallback page when a
  #     backend has zero ready endpoints. Always last so it only fires for
  #     upstream errors after auth has run. `fallback_errors: false` on a
  #     component drops it — for APIs whose clients expect the upstream's
  #     own 502/503/504 body (JSON), not an HTML page.
  # Order matters — Traefik applies middlewares head-first.
  ir_middlewares = {
    for name, c in local.normalized_components :
    name => concat(
      contains(keys(local.basic_auth_components), name) ? [{ name = "${name}-basic-auth" }] : [],
      contains(keys(local.zitadel_auth_components), name) ? var.oauth2_proxy_middlewares : [],
      var.fallback_errors_middleware == null || !try(c.fallback_errors, true) ? [] : [var.fallback_errors_middleware],
    )
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

  # Per-component tunnel/DNS attributes for `output.hostnames`.
  hostname_targets = {
    for name, c in local.normalized_components :
    name => {
      component    = name
      service      = local.component_service_urls[name]
      zone_id      = try(var.project_config.cloudflare_zone_id, null)
      http2_origin = try(c.http2_origin, false)
    }
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

  # Per-path request rate limits (`rate_limits:` in the component yaml),
  # keyed "<component>/<index>". Each entry gets its own Traefik RateLimit
  # middleware and its own IngressRoute rule on the component's whole-host
  # routes, so the limit applies to that path only. Clients are counted by
  # `CF-Connecting-IP`: every request arrives through the Cloudflare Tunnel,
  # so the socket peer is always cloudflared and the header carries the
  # real client.
  rate_limits = merge([
    for name, c in local.normalized_components : {
      for i, rl in try(c.rate_limits, []) :
      "${name}/${i}" => {
        component = name
        name      = "${name}-rate-limit-${i}"
        path      = rl.path
        methods   = try(rl.methods, [])
        average   = rl.average
        period    = try(rl.period, "1m")
        burst     = try(rl.burst, rl.average)
      }
    }
  ]...)

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

  # Components that opt into GCP Workload Identity Federation. Keyed
  # by component name → the GCP ServiceAccount email the projected
  # k8s SA token will impersonate via the WIF principalSet binding
  # (that binding itself lives in the GCP-side TF, not here).
  gcp_wif_components = {
    for name, c in local.normalized_components :
    name => try(c.gcp_wif.gcp_service_account, "")
    if try(c.gcp_wif, null) != null && try(c.gcp_wif.gcp_service_account, "") != ""
  }

  # Standalone WIF ServiceAccounts for chart-managed workloads — same
  # external_account shape as `gcp_wif_components`, but the engine emits
  # only the SA + ConfigMap (the chart owns the pod). Keyed by k8s SA
  # name → GCP SA email it impersonates.
  gcp_wif_service_accounts = {
    for sa_name, cfg in var.gcp_wif_service_accounts :
    sa_name => cfg.gcp_service_account
  }

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

# Configuration preconditions: each one fails the plan instead of letting
# a wrong project config reach the cluster.
resource "terraform_data" "config_checks" {
  lifecycle {
    # A routed component needs a template (`config/components/<name>.yaml`)
    # or an inline `envs.<env>.components.<name>` block.
    precondition {
      condition = alltrue([
        for name in local._component_names :
        contains(keys(var.components), name) || contains(keys(try(var.project_config.components, {})), name)
      ])
      error_message = "project '${local.namespace}' has a route to an unknown component. Referenced components: ${jsonencode(local._component_names)}. Available templates: ${jsonencode(keys(var.components))}. Inline overrides: ${jsonencode(keys(try(var.project_config.components, {})))}. Add `config/components/<name>.yaml` OR an inline `envs.<env>.components.<name>` block in the domain yaml."
    }
    # Anything else would silently render as a plain Deployment.
    precondition {
      condition = alltrue([
        for name, c in local.normalized_components : contains(["deployment", "app", "external"], c.kind)
      ])
      error_message = "project '${local.namespace}' has a component with an unknown `kind` (${jsonencode({ for name, c in local.normalized_components : name => c.kind if !contains(["deployment", "app", "external"], c.kind) })}). Supported: deployment, app, external."
    }
    # A component that asks for a shared service needs its
    # `services.<name>` toggle on in `config/platform.yaml`.
    precondition {
      condition     = !local.needs_db || var.mysql_host != null
      error_message = "project '${local.namespace}' has a component with `db: true` but `services.mysql` is disabled in config/platform.yaml. Either enable MySQL or drop `db: true` from the component spec."
    }
    precondition {
      condition     = !local.needs_postgres || var.postgres_host != null
      error_message = "project '${local.namespace}' has a component with `postgres: true` but `services.postgres` is disabled in config/platform.yaml. Either enable PostgreSQL or drop `postgres: true` from the component spec."
    }
    precondition {
      condition     = !local.needs_redis || var.redis_host != null
      error_message = "project '${local.namespace}' has a component with `redis: true` but `services.redis` is disabled in config/platform.yaml. Either enable Redis or drop `redis: true` from the component spec."
    }
    precondition {
      condition     = !local.needs_ollama || var.ollama_url != null
      error_message = "project '${local.namespace}' has a component with `ollama: true` but `services.ollama` is disabled in config/platform.yaml. Either enable Ollama or drop `ollama: true` from the component spec."
    }
    precondition {
      condition     = length(local.gcp_wif_components) == 0 || var.gcp_wif_pool_provider_audience != ""
      error_message = "project '${local.namespace}' has component(s) with `gcp_wif.gcp_service_account` set (${join(", ", keys(local.gcp_wif_components))}) but `services.gcp_wif.pool_provider_audience` is empty in config/platform.yaml. Either set the audience (`//iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>`) or drop `gcp_wif:` from the component spec(s)."
    }
    precondition {
      condition     = length(local.zitadel_auth_components) == 0 || (var.oauth2_proxy_middlewares != null && length(var.oauth2_proxy_middlewares) > 0)
      error_message = "project '${local.namespace}' has at least one component with `auth: zitadel` (${join(", ", keys(local.zitadel_auth_components))}) but the cluster-wide oauth2-proxy is not deployed — that gate is gated on `services.zitadel.enabled`. Either turn Zitadel on, or drop the `auth: zitadel` knob."
    }
    precondition {
      condition     = length(var.gcp_wif_service_accounts) == 0 || var.gcp_wif_pool_provider_audience != ""
      error_message = "project '${local.namespace}' declares gcp_wif_service_accounts (${join(", ", keys(var.gcp_wif_service_accounts))}) but `services.gcp_wif.pool_provider_audience` is empty in config/platform.yaml. Set the audience or drop the entries."
    }
    precondition {
      condition = alltrue([
        for name in local.operator_secret_literal_set :
        alltrue([
          for k in try(var.secrets[name].keys, []) :
          contains(keys(var.operator_secret_values[name]), k)
        ])
      ])
      error_message = "var.operator_secret_values supplies a literal entry whose inner map is missing a key declared under `secrets.<name>.keys` in the domain yaml. Project '${local.namespace}'. Each literal-mode Secret must cover every yaml-listed key. Add the missing key to terraform.tfvars or remove it from the domain yaml. (Vault-mode entries — yaml `vault: true` — bypass this check; VSO copies whatever's at the Vault path.)"
    }
    precondition {
      condition     = length(var.chart_oidc_apps) == 0 || var.zitadel_issuer_url != null
      error_message = "project '${local.namespace}' declares `chart_oidc_apps:` entries (${join(", ", keys(var.chart_oidc_apps))}) but `services.zitadel.enabled` is false. Either flip Zitadel on in `config/platform.yaml` or remove the chart_oidc_apps block."
    }
    precondition {
      condition     = length(local.app_components_with_oidc) == 0 || var.zitadel_issuer_url != null
      error_message = "project '${local.namespace}' has at least one `kind: app` component with `oidc.enabled: true` (${join(", ", keys(local.app_components_with_oidc))}) but `services.zitadel.enabled` is false. Either flip Zitadel on in `config/platform.yaml` or remove the oidc block."
    }
    precondition {
      condition     = length(var.argocd_bootstraps) == 0 || var.argocd_namespace != ""
      error_message = "project '${local.namespace}' declares `argocd_bootstraps:` entries but `argocd_namespace` is empty. Enable `services.argocd.enabled = true` in `config/platform.yaml` and re-apply."
    }
    precondition {
      condition = alltrue([
        for _, h in var.argocd_hostnames :
        try(h.cf_tunnel, true) || try(h.node_ip, "") != ""
      ])
      error_message = "every `argocd_hostnames` entry with `cf_tunnel: false` must set `node_ip:` to the node's real public IP — TF emits an unproxied A record there, bypassing the Cloudflare Tunnel. Project '${local.namespace}'."
    }
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
      },
      # Pod Security in warn + audit mode: violations are reported, nothing
      # is blocked. Raise to `enforce` per project once the audit is clean.
      var.pod_security_level == "" ? {} : {
        "pod-security.kubernetes.io/warn"  = var.pod_security_level
        "pod-security.kubernetes.io/audit" = var.pod_security_level
      },
      var.pod_security_enforce == "" ? {} : {
        "pod-security.kubernetes.io/enforce" = var.pod_security_enforce
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
