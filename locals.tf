locals {
  # Load raw domain configs from YAML files
  _domain_configs = {
    for f in fileset("${path.module}/config/domains", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/domains/${f}"))
  }

  # Expand domain × env → one entry per project/env combination.
  # Key / namespace: "{prefix}{slug}-{env}"  (e.g. "phost-paseka-co-prod")
  # Hostname per route: "{host_prefix}.{domain}" literally, host_prefix ""
  # collapses to the apex domain. Env does NOT leak into the hostname; if
  # two envs of the same domain need distinct hostnames, the operator
  # picks the prefixes explicitly.
  #
  # YAML shape:
  #   envs is a MAP keyed by env name; each value carries `routes` —
  #   another map whose keys are host prefixes (e.g. "", "www", "api")
  #   and whose values are component names drawn from
  #   `config/components/`. One IngressRoute is emitted per component,
  #   grouping every route that points at that component into a single
  #   Host(...) || Host(...) match. Components are DECOUPLED from
  #   hostnames: the same component can serve multiple prefixes, and
  #   different prefixes can serve different components.
  projects = {
    for entry in flatten([
      for _, cfg in local._domain_configs : [
        for env_name, env_spec in try(cfg.envs, {}) : {
          key                = "${cfg.slug}-${env_name}"
          name               = cfg.name # domain, e.g. "paseka.co"
          slug               = cfg.slug # e.g. "paseka-co"
          env                = env_name # "prod" | "dev" | ...
          namespace          = "${var.namespace_prefix}${cfg.slug}-${env_name}"
          cloudflare_zone_id = try(cfg.cloudflare_zone_id, null)
          routes             = try(env_spec.routes, {})
          limits             = try(env_spec.limits, cfg.limits, null)
        }
      ]
    ]) :
    entry.key => entry
  }

  # Reusable component definitions from config/components/*.yaml
  components = {
    for f in fileset("${path.module}/config/components", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/components/${f}"))
  }

  # Default namespace resource quota
  default_limits = yamldecode(file("${path.module}/config/limits/default.yaml"))
}
