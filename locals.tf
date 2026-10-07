locals {
  # Platform-service config. `config/platform.yaml` is gitignored; the
  # repo ships `.example` with every service off. Schema is
  # `services.<name>` → object; every field is optional and falls back
  # to the default below. Missing file = full defaults.
  _platform_defaults = {
    services = {
      # Pod-placement defaults — each shared service accepts
      # `node_selector` (map<string,string>) and `tolerations`
      # (list<toleration>) as optional yaml keys. Both empty by
      # default so the scheduler keeps current behaviour. See README
      # "Pod placement" for the shape; consumed by every service's
      # *.tf wiring file via `local.platform.services.X.<key>`.
      mysql = {
        enabled       = false
        node_selector = {}
        tolerations   = []
        resources     = null # null = module default
      }
      postgres = {
        enabled       = false
        node_selector = {}
        tolerations   = []
      }
      redis = {
        enabled       = false
        storage_class = ""
        node_selector = {}
        tolerations   = []
        affinity      = {}
        sentinel      = {}
      }
      ollama = {
        enabled        = false
        models         = []
        memory_request = "4Gi"
        memory_limit   = "16Gi"
        cpu_request    = "200m"
        cpu_limit      = "10"
        context_length = null # null = module default
        # Optional GPU offload. Default null = CPU-only StatefulSet.
        # Override in config/platform.yaml with the full object shape
        # (image, device_path, supplemental_groups, env) — see
        # platform.yaml.example for the expected keys and a worked
        # Intel Arc + Vulkan example.
        gpu           = null
        node_selector = {}
        tolerations   = []
        affinity      = {}
      }
      vault = {
        enabled                             = false
        hostname                            = ""
        storage_class                       = ""
        vault_config_operator_chart_version = "1.0.3"
      }
      argocd = {
        enabled       = false
        hostname      = ""
        namespace     = "argocd"
        node_selector = {}
        tolerations   = []
        # Chart-shaped `controller.resources`; {} = chart default.
        controller_resources = {}
        built_from_apps      = []
        # KV-v2 path with the Slack webhook (key `slack-webhook`); "" = no
        # Slack deploy notifications.
        slack_notifications_vault_path = ""
      }
      # Maintenance window defaults = the addons module's (reboot any time,
      # any day, UTC). Operators narrow it in config/platform.yaml —
      # `time_zone` makes the window wall-clock regardless of each node's
      # own OS timezone.
      kured = {
        enabled     = false
        time_zone   = "UTC"
        start_time  = "00:00"
        end_time    = "23:59"
        reboot_days = ["su", "mo", "tu", "we", "th", "fr", "sa"]
      }
      # Cluster log aggregation — VictoriaLogs store + Vector collector +
      # Grafana datasource (see modules/logging). Time-retained, searchable
      # logs in the existing Grafana, replacing node-local kubelet rotation.
      logging = {
        enabled          = false
        namespace        = "monitoring"
        retention_period = "30d"
        storage_class    = "longhorn"
        storage_size     = "50Gi"
        node_selector    = {}
        # Empty = store + collector only (no alerting). Set to a LOCAL mailbox
        # (e.g. an @example.com address Stalwart delivers without auth) to
        # wire vmalert LogsQL alerts → Alertmanager → email.
        alert_email = ""
        # From address and EHLO FQDN for alert mail; both required with
        # alert_email (Stalwart rejects a non-FQDN EHLO).
        smtp_from  = ""
        smtp_hello = ""
        # Operator-defined alert rules, MERGED on top of the generic default
        # set (`local._default_alert_rules`) by logging.tf — so the yaml only
        # lists ADDITIONS (e.g. app-specific substrings), not the defaults.
        alert_rules = {}
      }
      # Optional Cloudflare DNS-01 ACME solver — adds a second solver to
      # the Let's Encrypt ClusterIssuers gated by `dns_zones`. HTTP-01
      # stays the default for hosts outside those zones. Required for
      # Certificates whose hosts can't satisfy HTTP-01 (direct LB
      # endpoints with no port-80 listener — UDP/raw-TCP services bound
      # to a MetalLB VIP). Reuses the operator's existing
      # `TF_VAR_cloudflare_api_token` (no separate scoped token to
      # provision); the engine emits a Secret in `cert-manager` namespace
      # that addons references.
      dns01_cloudflare = {
        enabled   = false
        dns_zones = []
      }
      longhorn = {
        enabled          = false
        replica_count    = 3
        backup_b2_region = ""
        tolerations      = []
        tag_pools        = {}
      }
      metallb = {
        enabled                  = false
        controller_node_selector = {}
        controller_tolerations   = []
        speaker_node_selector    = {}
        speaker_tolerations      = []
        pools                    = {}
        shared_ip_annotations    = {}
      }
      minio = {
        enabled       = false
        storage_class = ""
        storage_size  = "50Gi"
        node_selector = {}
        tolerations   = []
        distributed   = {}
        buckets       = {}
      }
      github_runners = {
        enabled                  = false
        chart_version            = "0.14.2" # controller and scale sets must match
        controller_node_selector = {}
        controller_tolerations   = []
        scale_sets               = {}
      }
      coredns = {
        host_overrides  = {}
        zone_forwarders = {}
      }
      traefik_public = {
        enabled = false
        pools   = {}
      }
      cluster_oidc = {
        enabled           = false
        external_hostname = ""
        node_selector     = {}
        tolerations       = []
      }
      # Cluster-wide constants for GCP Workload Identity Federation.
      # `pool_provider_audience` must equal the full WIF pool provider
      # path the operator configured GCP-side (the same string GCP STS
      # validates against incoming projected SA token `aud` claims).
      # One audience per cluster — per-binding parameterisation is not
      # needed; the only per-component value is the impersonated GCP
      # SA email, which lives on each component yaml under `gcp_wif:`.
      # Disabled (empty audience) is the default; component-level
      # opt-in fails a plan-time check when the audience is empty.
      gcp_wif = {
        pool_provider_audience = ""
      }
      seafile = {
        enabled           = false
        namespace         = "seafile"
        image_tag         = "13.0.21"
        external_hostname = ""
        admin_email       = ""
        storage_class     = "longhorn"
        storage_size      = "100Gi"
        timezone          = "Etc/UTC"
        cpu_request       = "200m"
        cpu_limit         = "2"
        memory_request    = "512Mi"
        memory_limit      = "2Gi"
        node_selector     = {}
        tolerations       = []
      }
      security_scan = {
        enabled                      = false
        trivy_operator_chart_version = "0.36.0"
        node_selector                = {}
        extra_target_namespaces      = []
        service_monitor_enabled      = false
        alerts_enabled               = false
        alert_severities             = ["Critical"]
      }
      backup = {
        enabled                = false
        postgres_databases     = []
        mysql_databases        = []
        pv_paths               = []
        pv_node_selector       = {}
        pv_tolerations         = []
        schedule_postgres      = "0 3 * * *"
        schedule_mysql         = "15 3 * * *"
        schedule_redis         = "30 3 * * *"
        schedule_vault         = "45 3 * * *"
        schedule_pv            = "0 4 * * 0"
        schedule_prune         = "0 5 * * 0"
        retention_keep_daily   = 7
        retention_keep_weekly  = 4
        retention_keep_monthly = 6
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
        # Instance-wide OIDC token lifetimes. Defaults match
        # Zitadel's bundled defaults (12h access/id, 30d refresh,
        # 7d idle) so a clean install lands the same shape upstream
        # ships. Override to shorten — e.g. 5m access keeps OIDC
        # consumers re-fetching `/userinfo` close to the IdP's
        # current state, so role-grant changes (Zitadel UI / TF /
        # API) propagate to consumers (Stalwart, chat, ArgoCD)
        # within the access-token lifetime instead of being stuck
        # on stale tokens until LRU eviction or pod restart.
        oidc_settings = {
          access_token_lifetime         = "12h"
          id_token_lifetime             = "12h"
          refresh_token_expiration      = "720h"
          refresh_token_idle_expiration = "168h"
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
        node_selector = {}
        tolerations   = []
      }
      # Defaults for the planned `services.platform_dash` block. Not
      # consumed yet — the dashboard currently lives as a tenant
      # component under `config/domains/<domain>.yaml`. Scaffolding
      # for a future refactor that promotes the dashboard to
      # first-class platform infra (its own ns + module).
      platform_dash = {
        enabled  = false
        image    = ""
        replicas = 1
        hostname = ""
        resources = {
          requests = { cpu = "100m", memory = "128Mi" }
          limits   = { cpu = "500m", memory = "512Mi" }
        }
        node_selector = {}
        tolerations   = []
      }
      addons = {
        # Pod-placement + workload-kind override for the bundled
        # `terraform-k8s-addons` Traefik release. All three are
        # opt-in — leaving defaults preserves the chart's stock
        # `Deployment` with no toleration / nodeSelector.
        traefik_deployment_kind = null
        traefik_tolerations     = []
        traefik_node_selector   = {}
      }
      buildkitd = {
        # Cluster-internal BuildKit daemon for self-hosted runner
        # image builds. Disabled by default — opt in only when ARC
        # runners need a remote buildx driver.
        #
        # Trust model: CERN userns pattern. Container runs
        # `privileged: true` BUT under `hostUsers: false`, so the
        # privileged uid 0 inside the container is remapped to an
        # unprivileged uid on the host (kernel userns isolation).
        # See `buildkitd.tf` header for the full rationale.
        #
        # `host_path` is the cluster-node directory the cache slabs
        # land in (hostPath volume — survives Pod restarts but not
        # node moves; buildkitd is a single-replica daemon so node
        # affinity via `node_selector` keeps the cache pinned).
        # `mount_path` is the in-container path; defaults to the
        # rootful buildkit data dir.
        #
        # Readiness-probe knobs are exposed because the default
        # `period_seconds = 10` + `timeout_seconds = 1` killed the
        # Pod mid-build on busy clusters (`buildctl debug workers`
        # contends with the active build for the OCI worker lock).
        # Defaults below are the values that survived a real ARC
        # build cycle on this cluster.
        enabled                         = false
        image_tag                       = "v0.33.1"
        host_path                       = "/data/vol/buildkit-cache"
        mount_path                      = "/var/lib/buildkit"
        cpu_request                     = "200m"
        cpu_limit                       = "4"
        memory_request                  = "512Mi"
        memory_limit                    = "8Gi"
        readiness_initial_delay_seconds = 5
        readiness_period_seconds        = 60
        readiness_timeout_seconds       = 15
        readiness_failure_threshold     = 5
        node_selector                   = {}
        tolerations                     = []
      }

      # AirLLM — LLM gateway deployed from its public Helm chart (airllm.tf).
      # Environment specifics (hostname, zone, VIP) come from the gitignored
      # config/platform.yaml; these defaults keep the service off until then.
      airllm = {
        enabled            = false
        namespace          = "airllm"
        hostname           = ""
        cloudflare_zone_id = ""
        public_ip          = ""
        # Pinned release: Argo CD deploys the chart at this tag, so a merge to
        # the app repo's main never reaches live traffic by itself. Empty
        # image_tag lets the chart default to that tag's appVersion. Rolling
        # out a release = bump chart_revision here and apply.
        chart_revision = "v0.1.79"
        image_tag      = ""
        # Upstream chart repository (public). Override to run a fork.
        repo_url = "https://github.com/ipsupport-llc/ipsupport-airllm.git"
        # Node selector for the gateway pods (both replicas). Empty lets them
        # land on any node; set it to keep the voice path off nodes far from
        # its datastores and model servers.
        node_selector = {}
        # GCP Workload Identity Federation: the SA the pod impersonates so the
        # gateway's `vertex` provider mints OAuth2 tokens as its own cloud
        # identity, with no service-account key stored anywhere. Empty (default)
        # leaves the chart's block off. The pool coordinates are NOT repeated
        # here — airllm.tf derives them from `services.gcp_wif`.
        google_service_account = ""
      }

      # Speaches — self-hosted OpenAI-compatible STT/TTS server
      # (github.com/speaches-ai/speaches). CPU-only: upstream only ships
      # CPU/CUDA variants, no Intel GPU/Vulkan backend, so this doesn't
      # compete with Ollama for the GPU. Internal-only by default (no
      # hostname) — reached in-cluster as an OpenAI-compatible audio
      # provider target, e.g. by AirLLM.
      speaches = {
        enabled = false
        # NOT a k8s Namespace — the actual k8s namespace is hardcoded to
        # the shared `platform` one (speaches.tf uses
        # kubernetes_namespace_v1.platform directly, same as ollama/
        # airllm's postgres-setup Job). This only names the hostPath
        # subdirectory under host_volume_path for the model-cache PV.
        namespace     = "speaches"
        image         = "ghcr.io/speaches-ai/speaches:0.8.3-cpu@sha256:21e3df06d842fb7802ab470dd77c25f0e8c0d22950e8d8c6ae886e851af53ef8"
        storage_size  = "20Gi"
        node_selector = { "workload-tier" = "general" }
        cpu_request   = "200m"
        cpu_limit     = "2"
        # 4Gi OOMKilled (exit 137) loading faster-whisper-large-v3 for real
        # inference on CPU (confirmed live, 2026-08-30) — the ~3GB model
        # plus CTranslate2/ONNX runtime overhead needs real headroom beyond
        # just the on-disk model size.
        memory_request = "1Gi"
        memory_limit   = "8Gi"
      }

      # AI alert enrichment (alert_llm_enricher.tf) — adds an LLM-generated
      # diagnosis + action plan email alongside (never instead of) the
      # existing plain-text log-alert email. No-op unless
      # services.logging.alert_email is also set (nothing to attach a
      # webhook to otherwise). A tiny stdlib-only Python script, not a
      # built image — see scripts/alert-llm-enricher.py.
      alert_llm_enrichment = {
        enabled = false
        # Required when enabled. Use the chat default model: with
        # OLLAMA_MAX_LOADED_MODELS=1 a different model evicts it from VRAM
        # on every alert.
        ollama_model = ""
        # Language the diagnosis is written in (the email itself is English).
        language       = "English"
        cpu_request    = "50m"
        cpu_limit      = "500m"
        memory_request = "64Mi"
        memory_limit   = "256Mi"
        # From address and EHLO FQDN for the enriched alert mail.
        smtp_from  = ""
        smtp_hello = ""
      }
    }
  }
  _platform_file = "${path.module}/config/platform.yaml"
  # Decode the YAML string (file content, or "{}" when absent) — conditioning on
  # the string keeps the ternary's branch types consistent regardless of which
  # top-level keys the config declares, while still surfacing invalid-YAML errors.
  _platform_raw      = yamldecode(fileexists(local._platform_file) ? file(local._platform_file) : "{}")
  _platform_services = try(local._platform_raw.services, {})
  platform = {
    services = {
      mysql                = merge(local._platform_defaults.services.mysql, try(local._platform_services.mysql, {}))
      postgres             = merge(local._platform_defaults.services.postgres, try(local._platform_services.postgres, {}))
      redis                = merge(local._platform_defaults.services.redis, try(local._platform_services.redis, {}))
      ollama               = merge(local._platform_defaults.services.ollama, try(local._platform_services.ollama, {}))
      zitadel              = merge(local._platform_defaults.services.zitadel, try(local._platform_services.zitadel, {}))
      vault                = merge(local._platform_defaults.services.vault, try(local._platform_services.vault, {}))
      argocd               = merge(local._platform_defaults.services.argocd, try(local._platform_services.argocd, {}))
      kured                = merge(local._platform_defaults.services.kured, try(local._platform_services.kured, {}))
      logging              = merge(local._platform_defaults.services.logging, try(local._platform_services.logging, {}))
      dns01_cloudflare     = merge(local._platform_defaults.services.dns01_cloudflare, try(local._platform_services.dns01_cloudflare, {}))
      longhorn             = merge(local._platform_defaults.services.longhorn, try(local._platform_services.longhorn, {}))
      metallb              = merge(local._platform_defaults.services.metallb, try(local._platform_services.metallb, {}))
      minio                = merge(local._platform_defaults.services.minio, try(local._platform_services.minio, {}))
      github_runners       = merge(local._platform_defaults.services.github_runners, try(local._platform_services.github_runners, {}))
      backup               = merge(local._platform_defaults.services.backup, try(local._platform_services.backup, {}))
      platform_dash        = merge(local._platform_defaults.services.platform_dash, try(local._platform_services.platform_dash, {}))
      addons               = merge(local._platform_defaults.services.addons, try(local._platform_services.addons, {}))
      buildkitd            = merge(local._platform_defaults.services.buildkitd, try(local._platform_services.buildkitd, {}))
      coredns              = merge(local._platform_defaults.services.coredns, try(local._platform_services.coredns, {}))
      cluster_oidc         = merge(local._platform_defaults.services.cluster_oidc, try(local._platform_services.cluster_oidc, {}))
      gcp_wif              = merge(local._platform_defaults.services.gcp_wif, try(local._platform_services.gcp_wif, {}))
      seafile              = merge(local._platform_defaults.services.seafile, try(local._platform_services.seafile, {}))
      security_scan        = merge(local._platform_defaults.services.security_scan, try(local._platform_services.security_scan, {}))
      traefik_public       = merge(local._platform_defaults.services.traefik_public, try(local._platform_services.traefik_public, {}))
      airllm               = merge(local._platform_defaults.services.airllm, try(local._platform_services.airllm, {}))
      speaches             = merge(local._platform_defaults.services.speaches, try(local._platform_services.speaches, {}))
      alert_llm_enrichment = merge(local._platform_defaults.services.alert_llm_enrichment, try(local._platform_services.alert_llm_enrichment, {}))
    }
    # Operator-supplied monitoring extras (gitignored config). Generic engine
    # in prometheus_rules.tf renders whatever is under `monitoring.prometheus_rules`
    # into a PrometheusRule — app/tenant-specific exprs stay out of tracked TF.
    monitoring = try(local._platform_raw.monitoring, {})
    # Operator gate allowlist (`forward_auth.allowed_emails` / `allowed_domains`).
    forward_auth = try(local._platform_raw.forward_auth, {})
  }

  # Load raw domain configs from YAML files
  _domain_configs = {
    for f in fileset("${path.module}/config/domains", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/domains/${f}"))
  }

  # Expand domain × env → one entry per project/env combination.
  # Key / namespace: "{prefix}{slug}-{env}"  (e.g. "phost-example-com-prod")
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
          name               = cfg.name # domain, e.g. "example.com"
          slug               = cfg.slug # e.g. "example-com"
          env                = env_name # "prod" | "dev" | ...
          namespace          = "${var.namespace_prefix}${cfg.slug}-${env_name}"
          cloudflare_zone_id = try(cfg.cloudflare_zone_id, null)
          routes             = try(env_spec.routes, {})
          # Argo CD-managed hostnames declared per-env. Keyed by host
          # prefix (resolves to `<prefix>.<domain>`); each entry sets
          # `cf_tunnel: bool` (default true) and optional `node_ip:` for
          # the no-tunnel A-record path. TF only plumbs DNS + tunnel
          # rule — IngressRoute / Service live in the operator's deploy
          # repo, applied by Argo CD.
          argocd_hostnames = try(env_spec.argocd_hostnames, {})
          # Pod Security level enforced on the namespace (`baseline`,
          # `restricted`); "" = report only (warn/audit, see modules/project).
          pod_security_enforce = try(env_spec.pod_security_enforce, "")
          # Argo CD bootstrap App-of-Apps roots for this env, keyed by
          # short name. Each entry → one root Application
          # (`<ns>-<key>-bootstrap`) + sub-apps recursing under it.
          # AppProject sourceRepos is the union across entries, so
          # multi-repo sub-Applications cross-referencing peer repos
          # pass the allowlist (e.g. a backend chart and a frontend
          # chart living in separate repos but sharing one project
          # namespace). Empty map = no Argo CD bootstrap (project
          # has no Argo footprint unless `argocd_hostnames` is set).
          argocd_bootstraps = try(env_spec.argocd_bootstraps, {})
          # Per-env shared-service provisioning flags. Same shape as
          # the per-component `postgres: true` / `redis: true` /
          # `ollama: true` knobs but applied at the project layer —
          # engine emits per-namespace ACL credentials (Postgres role
          # + DB, Redis ACL user, Ollama Service URL Secret) WITHOUT
          # requiring a `kind: deployment/app` component to opt in.
          # Use for Argo CD-managed workloads whose pods aren't
          # TF-emitted but still need platform shared-service
          # credentials in their namespace.
          shared_services = try(env_spec.shared_services, {})
          # Generic operator-defined Secrets — engine emits a
          # `kubernetes_secret_v1` per entry in the project namespace.
          # Use for app-specific shared-secrets (e.g. an apikey a
          # chart's `existingSecret` references). Each entry's `keys`
          # list defines data keys; a single random_password per
          # entry seeds the value across every key. Sharing one
          # value across keys lets an operator point a chart's
          # multi-env-var Secret consumer at one Secret without
          # rotating multiple downstream registrations.
          secrets = try(env_spec.secrets, {})
          # Per-env git-sync deploy keys. Each entry → engine emits a
          # `kubernetes.io/ssh-auth` Secret named `git-deploy-key-<id>`
          # in the project namespace, populated from Vault path
          # `secret/data/tenants/<slug>/git-deploy-keys/<id>` (single
          # data key `sshPrivateKey`). Tenant uploads the key into
          # Vault themselves via Zitadel SSO with the `tenant_<slug>`
          # role grant — operator out of the loop. `host` picks the
          # `known_hosts` line; default `github.com`.
          git_deploy_keys          = try(env_spec.git_deploy_keys, {})
          image_pull_secrets       = try(env_spec.image_pull_secrets, {})
          gcp_wif_service_accounts = try(env_spec.gcp_wif_service_accounts, {})
          # Engine-managed Zitadel OIDC clients for chart-deployed
          # apps. Engine creates a Zitadel Project + OIDC Application
          # per entry and emits a Secret in the project namespace
          # with the four standard keys (issuer / client_id /
          # client_secret / random session secret). Lets a chart's
          # `envFrom: secretRef:` pick up the credentials without
          # any click-ops in the Zitadel console.
          chart_oidc_apps = try(env_spec.chart_oidc_apps, {})
          limits          = try(env_spec.limits, cfg.limits, null)
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

  # Manual DNS records from `config/domains/<domain>.yaml#dns:`. Domain-
  # scoped (not env-scoped) — DNS records are facts about the zone, not
  # about an env. Auto-generated CNAMEs for `envs.*.routes:` are emitted
  # separately by cloudflare.tf via `local.all_hostnames`.
  #
  # for_each key = "{domain_key}|{type}|{name}|{md5(content|data)}". The
  # content is part of the key because a zone can hold several records of
  # one type and name (TXT at `@`, multiple MX). Re-ordering the YAML list
  # does not churn the plan; editing a record's content replaces that one
  # record (delete + create) instead of updating it in place.
  manual_dns_records = {
    for entry in flatten([
      for domain_key, cfg in local._domain_configs : [
        for rec in try(cfg.dns, []) : {
          domain_key = domain_key
          zone_id    = cfg.cloudflare_zone_id
          # `name` keeps the YAML form (`@`, `_dmarc`, `mail`) so the
          # for_each key stays stable. The FQDN form lives in `fqdn`
          # below — Cloudflare provider v5 requires FQDN at the
          # resource level, but routing the FQDN into for_each would
          # destroy+recreate every record on the v4→v5 transition.
          name = rec.name
          fqdn = (
            rec.name == "@" ? cfg.name :
            (rec.name == cfg.name || endswith(rec.name, ".${cfg.name}")) ? rec.name :
            "${rec.name}.${cfg.name}"
          )
          type     = rec.type
          content  = try(rec.content, null)
          data     = try(rec.data, null)
          ttl      = try(rec.ttl, 1)
          proxied  = try(rec.proxied, false)
          priority = try(rec.priority, null)
          comment  = try(rec.comment, null)
        }
      ]
    ]) : "${entry.domain_key}|${entry.type}|${entry.name}|${md5(coalesce(entry.content, jsonencode(entry.data)))}" => entry
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

  # Mail-stack settings. Sourced from the domain yaml carrying
  # `mail.primary: true` — exactly one tenant domain owns the
  # platform's mail stack at a time, the others are routed elsewhere.
  # `null` when no domain opts in (mail stack stays uncreated).
  _mail_domain_keys = [
    for k, cfg in local._domain_configs : k if try(cfg.mail.primary, false)
  ]
  _mail_domain_key = length(local._mail_domain_keys) > 0 ? local._mail_domain_keys[0] : null
  _mail_raw        = local._mail_domain_key == null ? null : local._domain_configs[local._mail_domain_key]
  mail = local._mail_domain_key == null ? null : merge(
    {
      hostname             = "mail.${local._mail_raw.name}"
      smtp_relay_listen_ip = ""
      spf_authorized_ip    = ""
      dkim_selector        = "stalwart"
      dmarc_policy         = "quarantine"
      smarthost = {
        address             = ""
        port                = 25
        implicit_tls        = false
        allow_invalid_certs = false
        username            = ""
      }
    },
    try(local._mail_raw.mail, {}),
    {
      primary_domain     = local._mail_raw.name
      cloudflare_zone_id = try(local._mail_raw.cloudflare_zone_id, "")
      smarthost = merge(
        {
          address             = ""
          port                = 25
          implicit_tls        = false
          allow_invalid_certs = false
          username            = ""
        },
        try(local._mail_raw.mail.smarthost, {}),
      )
    },
  )
}
