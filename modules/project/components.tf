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

  # GCP Workload Identity Federation — pass the per-component
  # ConfigMap name + the cluster-wide audience. Both stay null/""
  # for components that did not opt in, which collapses every
  # related resource in modules/component to zero.
  gcp_wif_credential_configmap_name = contains(keys(local.gcp_wif_components), each.key) ? (
    kubernetes_config_map_v1.gcp_wif_credential_config[each.key].metadata[0].name
  ) : null
  gcp_wif_audience = contains(keys(local.gcp_wif_components), each.key) ? var.gcp_wif_pool_provider_audience : ""

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
  storage_node  = try(each.value.storage_node, "")
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

# One RateLimit middleware per `rate_limits:` entry; the IngressRoute
# attaches it only to that entry's path rule.
resource "kubectl_manifest" "rate_limit_middleware" {
  for_each = local.rate_limits

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = each.value.name
      namespace = local.namespace
      labels    = module.project_label.tags
    }
    spec = {
      rateLimit = {
        average = each.value.average
        period  = each.value.period
        burst   = each.value.burst
        sourceCriterion = {
          requestHeaderName = "CF-Connecting-IP"
        }
      }
    }
  })
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
