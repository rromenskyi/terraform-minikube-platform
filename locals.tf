locals {
  # Platform-service config. `config/platform.yaml` is gitignored; the
  # repo ships `.example` with every service off. Schema is
  # `services.<name>` → object; every field is optional and falls back
  # to the default below. Missing file = full defaults.
  _platform_defaults = {
    services = {
      mysql = {
        enabled = false
      }
      postgres = {
        enabled = false
      }
      redis = {
        enabled = false
      }
      ollama = {
        enabled        = false
        models         = ["deepseek-r1:1.5b"]
        memory_request = "4Gi"
        memory_limit   = "16Gi"
        cpu_request    = "200m"
        cpu_limit      = "10"
        # Optional GPU offload. Default null = CPU-only StatefulSet.
        # Override in config/platform.yaml with the full object shape
        # (image, device_path, supplemental_groups, env) — see
        # platform.yaml.example for the expected keys and a worked
        # Intel Arc + Vulkan example.
        gpu = null
      }
      zitadel = {
        enabled              = false
        external_domain      = ""
        first_admin_email    = ""
        first_admin_username = "zitadel-admin"
        login_policy = {
          allow_register          = false
          allow_external_idp      = true
          allow_username_password = true
        }
        # Provider transport — how the Zitadel TF provider (gRPC)
        # reaches the Zitadel API. Default = `public`: provider hits
        # the real ExternalDomain over HTTPS, which works on any
        # reasonable ingress chain that forwards HTTP/2 trailers.
        # Override to `port_forward` only on infra where the proxy
        # strips gRPC trailers (Cloudflare pure-proxy mode is the
        # known offender) — `./tf` wrapper detects the mode and runs
        # `kubectl port-forward svc/zitadel 8080:8080` for the apply
        # window. Both modes set `transport_headers.Host =
        # external_domain` so Zitadel multi-tenant routing matches.
        provider = {
          mode     = "public"
          host     = "" # empty = use external_domain
          port     = 443
          insecure = false
        }
      }
    }
  }
  _platform_file     = "${path.module}/config/platform.yaml"
  _platform_raw      = fileexists(local._platform_file) ? yamldecode(file(local._platform_file)) : {}
  _platform_services = try(local._platform_raw.services, {})
  platform = {
    services = {
      mysql    = merge(local._platform_defaults.services.mysql, try(local._platform_services.mysql, {}))
      postgres = merge(local._platform_defaults.services.postgres, try(local._platform_services.postgres, {}))
      redis    = merge(local._platform_defaults.services.redis, try(local._platform_services.redis, {}))
      ollama   = merge(local._platform_defaults.services.ollama, try(local._platform_services.ollama, {}))
      zitadel  = merge(local._platform_defaults.services.zitadel, try(local._platform_services.zitadel, {}))
    }
  }

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
          # Optional per-project component overrides. Top-level keys here
          # win over the matching keys in `config/components/<name>.yaml`
          # via shallow merge — provide a full replacement value for any
          # nested structure (lists like `storage:` are replaced wholesale,
          # not deep-merged). Lets a generic component template (e.g.
          # `web.yaml` = `nginx:alpine`+port+replicas) be reused across
          # projects with per-tenant tweaks (storage block, replica count,
          # resource caps, …) without spawning a per-project component yaml.
          components = try(env_spec.components, {})
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

  # Resource-quota settings per namespace. `config/limits/<namespace>.yaml`
  # overrides `config/limits/default.yaml` — e.g. `config/limits/platform.yaml`
  # bumps the root platform namespace above the tenant-default tier
  # because Ollama alone can burn 10 CPU during inference.
  namespace_limits = {
    for f in fileset("${path.module}/config/limits", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/limits/${f}"))
  }
  default_limits = local.namespace_limits.default
}
