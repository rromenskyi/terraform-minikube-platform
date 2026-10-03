# AirLLM — self-hosted LLM gateway (github.com/ipsupport-llc/ipsupport-airllm),
# deployed from its PUBLIC Helm chart via an Argo CD Application.
#
# Split of concerns (the public repo must carry NO trace of this install):
#   - the app repo ships a generic chart (existingSecret contract, external
#     Postgres/Redis, chart ingress off);
#   - THIS file (tracked, generic — no hostnames/secrets) renders the
#     Application, provisions the database, and emits the runtime Secret;
#   - environment specifics (hostname, zone id, pool VIP) live in the
#     gitignored `config/platform.yaml` under `services.airllm`.
#
# Exposure is DIRECT (no Cloudflare tunnel/proxy):
# unproxied A record → traefik_public VIP → IngressRoute (websecure) with a
# cert-manager Let's Encrypt certificate.

locals {
  airllm = local.platform.services.airllm # defaults + gitignored overrides, normalized in locals.tf

  airllm_instances = local.airllm.enabled ? toset(["enabled"]) : toset([])
  airllm_enabled   = local.airllm.enabled
  airllm_repo_url  = local.airllm.repo_url
  airllm_db        = "airllm"

  # ── GCP Workload Identity Federation ──────────────────────────────────────
  # The chart wants the pool coordinates as three separate values; the platform
  # already carries them as the one audience string every other WIF consumer on
  # this cluster uses. Derive them instead of re-declaring them: the audience is
  # rendered into both the projected token and the credential config, and a
  # mismatch is rejected only by STS at the first token refresh — hours after a
  # rollout that looked clean.
  airllm_wif_enabled = local.airllm.google_service_account != ""

  # //iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>
  _airllm_wif_pattern = "^//iam\\.googleapis\\.com/projects/(?P<project_number>[0-9]+)/locations/global/workloadIdentityPools/(?P<pool_id>[^/]+)/providers/(?P<provider_id>[^/]+)$"
  # A non-match must reach the precondition below with an actionable message
  # rather than dying inside `regex()`, hence `try` over a bare call.
  _airllm_wif_unparsed = { project_number = "", pool_id = "", provider_id = "" }
  airllm_wif = local.airllm_wif_enabled ? try(
    regex(local._airllm_wif_pattern, local.platform.services.gcp_wif.pool_provider_audience),
    local._airllm_wif_unparsed,
  ) : local._airllm_wif_unparsed
}

# ── Namespace ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "airllm" {
  for_each = local.airllm_instances

  metadata {
    name = local.airllm.namespace
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "airllm"
    })
  }
}

# ── Database on the shared platform Postgres ────────────────────────────────
# Same shape as the Zitadel provisioning job: idempotent psql against the
# shared instance using the superuser Secret; the generated app password
# never leaves TF state + the runtime Secret below.

resource "random_password" "airllm_db" {
  for_each = local.airllm_instances

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "airllm_postgres_setup_env" {
  for_each = local.airllm_instances

  metadata {
    name      = "airllm-postgres-setup"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = module.platform_label.tags
  }

  data = {
    SETUP_PASSWORD = "${random_password.airllm_db["enabled"].result}"
  }
}

resource "kubernetes_job_v1" "airllm_postgres_setup" {
  for_each = local.airllm_instances

  metadata {
    name      = "airllm-postgres-setup"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
    labels    = merge(module.platform_label.tags, { app = "airllm" })
  }

  spec {
    backoff_limit = 6
    # No TTL — TF-managed Job, self-delete causes re-plan churn (see the
    # postgres module's pg_extensions Job for the full rationale).

    template {
      metadata {
        labels = merge(module.platform_label.tags, { app = "airllm", job = "airllm-postgres-setup" })
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "psql"
          image = "postgres:18.6-alpine"

          # Password from a Secret, not the command line: Job specs are
          # readable far more widely than Secrets.
          env {
            name = "SETUP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.airllm_postgres_setup_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = module.postgres.superuser_secret_name
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          command = ["sh", "-ec"]
          args = [
            join("\n", [
              "until pg_isready -h ${module.postgres.host} -U postgres; do sleep 2; done",
              "psql -h ${module.postgres.host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.airllm_db}'\" | grep -q 1 || psql -h ${module.postgres.host} -U postgres -c \"CREATE ROLE \\\"${local.airllm_db}\\\" WITH LOGIN PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${module.postgres.host} -U postgres -c \"ALTER ROLE \\\"${local.airllm_db}\\\" WITH PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${module.postgres.host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.airllm_db}'\" | grep -q 1 || psql -h ${module.postgres.host} -U postgres -c \"CREATE DATABASE \\\"${local.airllm_db}\\\" OWNER \\\"${local.airllm_db}\\\"\"",
              "psql -h ${module.postgres.host} -U postgres -c \"ALTER DATABASE \\\"${local.airllm_db}\\\" OWNER TO \\\"${local.airllm_db}\\\"\"",
            ]),
          ]

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "3m"
    update = "3m"
  }
}

# ── Runtime Secret (chart `existingSecret` contract) ────────────────────────
# All values are TF-generated or composed from platform-internal creds — no
# operator-supplied secrets here (provider API keys are entered later in the
# console and encrypted app-side with the master key).

resource "random_bytes" "airllm_master_key" {
  for_each = local.airllm_instances
  length   = 32
}

resource "random_bytes" "airllm_session_key" {
  for_each = local.airllm_instances
  length   = 32
}

resource "random_password" "airllm_admin" {
  for_each = local.airllm_instances

  length  = 24
  special = false
}

# Own Redis identity instead of the shared `default` superuser: the
# gateway's keys all live under `air:` (usage counters, locks, login
# throttling). The ACL keeper in the Redis namespace applies this line to
# every node (see modules/redis).
resource "random_password" "airllm_redis" {
  for_each = local.airllm_instances
  length   = 32
  special  = false
}

# Same ACL line in the keeper's dedicated namespace (see modules/redis).
resource "kubernetes_secret_v1" "airllm_redis_acl_scoped" {
  for_each = local.airllm_instances

  metadata {
    name      = "redis-acl-airllm"
    namespace = module.redis.acl_namespace
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/component" = "airllm"
      "platform.local/redis-acl"    = "true"
    })
  }

  data = {
    setuser = "airllm on #${sha256(random_password.airllm_redis["enabled"].result)} ~air:* &air:* +@all -@dangerous +info"
  }
}

resource "kubernetes_secret_v1" "airllm" {
  for_each = local.airllm_instances

  metadata {
    name      = "airllm-secrets"
    namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "airllm" })
  }

  data = {
    "database-url"   = "postgres://${local.airllm_db}:${random_password.airllm_db["enabled"].result}@${module.postgres.host}:5432/${local.airllm_db}?sslmode=disable"
    "redis-url"      = "redis://airllm:${random_password.airllm_redis["enabled"].result}@${module.redis.host}:${module.redis.port}/0"
    "master-key"     = random_bytes.airllm_master_key["enabled"].base64
    "session-key"    = random_bytes.airllm_session_key["enabled"].base64
    "admin-password" = random_password.airllm_admin["enabled"].result
  }
}

# ── Argo CD Application (public chart, values inline) ───────────────────────

resource "kubectl_manifest" "airllm_application" {
  for_each = local.airllm_instances

  depends_on = [
    kubernetes_secret_v1.airllm,
    kubernetes_job_v1.airllm_postgres_setup,
  ]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = "airllm"
      namespace  = local.platform.services.argocd.namespace
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
      labels = merge(module.platform_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = {
      project = "platform"

      source = {
        repoURL        = local.airllm_repo_url
        path           = "deploy/helm/airllm"
        targetRevision = local.airllm.chart_revision
        helm = {
          valuesObject = {
            existingSecret = kubernetes_secret_v1.airllm["enabled"].metadata[0].name
            image = {
              repository = "ghcr.io/ipsupport-llc/ipsupport-airllm"
              tag        = local.airllm.image_tag
            }
            config = {
              env           = "prod"
              authMode      = "local"
              adminUsername = "admin"
            }
            app = {
              # Two replicas so losing one pod does not interrupt calls; the
              # disruption budget keeps a drain from taking both. On a
              # single-node cluster this guards against losing a pod, not the
              # node. Provider concurrency caps and round-robin counters are
              # per replica: a provider's max_concurrency admits twice that
              # many requests in total.
              replicaCount        = 2
              autoscaling         = { enabled = false }
              podDisruptionBudget = { enabled = true, maxUnavailable = 1 }
              ingress             = { enabled = false } # platform IngressRoute below owns the route
              # The image's USER is the name `app` (non-numeric), which k8s
              # can't verify against the chart's runAsNonRoot — pin the UID
              # the image is built for (Dockerfile chowns /var/lib/airllm to
              # 10001).
              securityContext = { runAsUser = 10001 }
              # Chart default (128Mi/512Mi) is tight for a gateway proxying
              # streaming completion bodies under real concurrent load —
              # bumped 2026-08-19 at the operator's request.
              resources = {
                requests = { cpu = "100m", memory = "256Mi" }
                limits   = { cpu = "1", memory = "2Gi" }
              }
            }
            dlpBert = {
              enabled = true
              image = {
                repository = "ghcr.io/ipsupport-llc/ipsupport-airllm-dlp-bert"
                tag        = local.airllm.image_tag # separate artifact — pin explicitly (chart guidance)
              }
              replicaCount = 1
              autoscaling  = { kind = "none" } # single box — scale later via hpa/keda values
            }
            metrics = {
              serviceMonitor = { enabled = true }
              dashboards     = { enabled = true }
            }
            # Off unless an SA to impersonate is configured, and then the only
            # thing it changes is that the pod gains a cloud identity — the
            # chart renders nothing here when disabled. projectNumber is a
            # STRING on purpose: as a number, YAML round-trips it into
            # scientific notation and the audience STS sees is garbage.
            googleWorkloadIdentity = {
              enabled        = local.airllm_wif_enabled
              projectNumber  = local.airllm_wif.project_number
              poolId         = local.airllm_wif.pool_id
              providerId     = local.airllm_wif.provider_id
              serviceAccount = local.airllm.google_service_account
            }
          }
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = local.airllm.namespace
      }

      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=false"]
      }
    }
  })

  lifecycle {
    precondition {
      condition     = !local.airllm_wif_enabled || local.airllm_wif.project_number != ""
      error_message = "services.airllm.google_service_account is set (${local.airllm.google_service_account}) but services.gcp_wif.pool_provider_audience is empty or malformed in config/platform.yaml. It must read //iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER> — the chart derives the pool coordinates from it. Either set it or drop google_service_account."
    }
  }
}

# ── Direct exposure: unproxied A record + LE cert + IngressRoute ─────────────

resource "cloudflare_dns_record" "airllm" {
  for_each = { for k in local.airllm_instances : k => k if local.airllm.hostname != "" && local.airllm.cloudflare_zone_id != "" }

  zone_id = local.airllm.cloudflare_zone_id
  name    = local.airllm.hostname
  type    = "A"
  content = local.airllm.public_ip
  ttl     = 300
  proxied = false
  comment = "AirLLM console/API — direct to traefik_public VIP (no CF proxy)"
}

resource "kubectl_manifest" "airllm_certificate" {
  for_each = { for k in local.airllm_instances : k => k if local.airllm.hostname != "" }

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "airllm-tls"
      namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    }
    spec = {
      secretName = "airllm-tls"
      issuerRef  = { kind = "ClusterIssuer", name = "letsencrypt-production" }
      dnsNames   = [local.airllm.hostname]
    }
  })
}

# Plain-HTTP hits (e.g. a client configured with http://…/v1) otherwise fall
# through to the cluster 404 fallback — redirect them to https instead.
resource "kubectl_manifest" "airllm_redirect_middleware" {
  for_each = { for k in local.airllm_instances : k => k if local.airllm.hostname != "" }

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "airllm-https-redirect"
      namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    }
    spec = {
      redirectScheme = { scheme = "https", permanent = true }
    }
  })
}

resource "kubectl_manifest" "airllm_ingressroute_web" {
  for_each = { for k in local.airllm_instances : k => k if local.airllm.hostname != "" }

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "airllm-web-redirect"
      namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match       = "Host(`${local.airllm.hostname}`)"
        kind        = "Rule"
        middlewares = [{ name = "airllm-https-redirect" }]
        services    = [{ name = "airllm", port = 8080 }] # unreachable past the redirect; Traefik requires a service
      }]
    }
  })
}

resource "kubectl_manifest" "airllm_ingressroute" {
  for_each = { for k in local.airllm_instances : k => k if local.airllm.hostname != "" }

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "airllm"
      namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`${local.airllm.hostname}`)"
        kind  = "Rule"
        services = [{
          name = "airllm"
          port = 8080
        }]
      }]
      tls = { secretName = "airllm-tls" }
    }
  })
}
