# AirLLM — self-hosted LLM gateway (github.com/ipsupport-llc/ipsupport-airllm),
# one instance, deployed from its PUBLIC Helm chart via an Argo CD Application.
#
# Split of concerns (the public repo must carry NO trace of this install):
#   - the app repo ships a generic chart (existingSecret contract, external
#     Postgres/Redis, chart ingress off);
#   - this module renders the Application, provisions the database (and
#     optionally seeds it from another instance's), and emits the runtime
#     Secret;
#   - environment specifics (hostname, zone id, VIP) come from the caller.
#
# Exposure is DIRECT (no Cloudflare tunnel/proxy):
# unproxied A record → traefik_public VIP → IngressRoute (websecure) with a
# cert-manager Let's Encrypt certificate.

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
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

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
  routed    = var.enabled && var.hostname != "" ? toset(["enabled"]) : toset([])
  db        = var.database_name
  pg        = var.postgres_host

  master_key = var.master_key != "" ? var.master_key : one([for k in random_bytes.master_key : k.base64])

  # ── GCP Workload Identity Federation ──────────────────────────────────────
  # The chart wants the pool coordinates as three separate values; the platform
  # already carries them as the one audience string every other WIF consumer on
  # this cluster uses. Derive them instead of re-declaring them: the audience is
  # rendered into both the projected token and the credential config, and a
  # mismatch is rejected only by STS at the first token refresh — hours after a
  # rollout that looked clean.
  wif_enabled = var.google_service_account != ""

  # //iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>
  _wif_pattern = "^//iam\\.googleapis\\.com/projects/(?P<project_number>[0-9]+)/locations/global/workloadIdentityPools/(?P<pool_id>[^/]+)/providers/(?P<provider_id>[^/]+)$"
  # A non-match must reach the precondition below with an actionable message
  # rather than dying inside `regex()`, hence `try` over a bare call.
  _wif_unparsed = { project_number = "", pool_id = "", provider_id = "" }
  wif = local.wif_enabled ? try(
    regex(local._wif_pattern, var.gcp_wif_audience),
    local._wif_unparsed,
  ) : local._wif_unparsed

  # Without OIDC the chart gets exactly the values it always had, so turning
  # this module on for an existing install renders no change.
  config = merge(
    {
      env           = var.app_env
      authMode      = var.oidc == null ? "local" : "oidc"
      adminUsername = "admin"
    },
    var.oidc == null ? {} : {
      oidc = {
        issuer      = var.oidc.issuer
        clientId    = var.oidc.client_id
        redirectUrl = "https://${var.hostname}/auth/callback"
        scopes      = "openid profile email" # SPACE-delimited: the app splits on whitespace
        rolesClaim  = var.oidc.roles_claim
        roleMap     = var.oidc.role_map
      }
    },
  )
}

# ── Namespace ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(var.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "airllm"
    })
  }
}

# ── Database on the shared platform Postgres ────────────────────────────────
# Same shape as the Zitadel provisioning job: idempotent psql against the
# shared instance using the superuser Secret; the generated app password
# never leaves TF state + the runtime Secret below.

resource "random_password" "db" {
  for_each = local.instances

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "postgres_setup_env" {
  for_each = local.instances

  metadata {
    name      = "${var.name}-postgres-setup"
    namespace = var.setup_namespace
    labels    = var.tags
  }

  data = {
    SETUP_PASSWORD = "${random_password.db["enabled"].result}"
  }
}

resource "kubernetes_job_v1" "postgres_setup" {
  for_each = local.instances

  metadata {
    name      = "${var.name}-postgres-setup"
    namespace = var.setup_namespace
    labels    = merge(var.tags, { app = var.name })
  }

  spec {
    backoff_limit = 6
    # No TTL — TF-managed Job, self-delete causes re-plan churn (see the
    # postgres module's pg_extensions Job for the full rationale).

    template {
      metadata {
        labels = merge(var.tags, { app = var.name, job = "${var.name}-postgres-setup" })
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
                name = kubernetes_secret_v1.postgres_setup_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env {
            name = "PGPASSWORD"
            value_from {
              secret_key_ref {
                name = var.postgres_superuser_secret
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          command = ["sh", "-ec"]
          args = [
            join("\n", [
              "until pg_isready -h ${local.pg} -U postgres; do sleep 2; done",
              "psql -h ${local.pg} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.db}'\" | grep -q 1 || psql -h ${local.pg} -U postgres -c \"CREATE ROLE \\\"${local.db}\\\" WITH LOGIN PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${local.pg} -U postgres -c \"ALTER ROLE \\\"${local.db}\\\" WITH PASSWORD '$SETUP_PASSWORD'\"",
              "psql -h ${local.pg} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.db}'\" | grep -q 1 || psql -h ${local.pg} -U postgres -c \"CREATE DATABASE \\\"${local.db}\\\" OWNER \\\"${local.db}\\\"\"",
              "psql -h ${local.pg} -U postgres -c \"ALTER DATABASE \\\"${local.db}\\\" OWNER TO \\\"${local.db}\\\"\"",
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

# One-time copy of another instance's database (e.g. a dev instance starting
# from prod's data). It only fills an EMPTY database: once the copy (or the
# app's own migrations) has created tables, a re-run is a no-op, so the Job
# never overwrites what the instance has since written. The dump is read as
# the superuser and restored as the instance's own role, without owners or
# grants, so every copied object belongs to that role and its migrations can
# alter it. pg_dump reads one consistent snapshot of a live database.
resource "kubernetes_job_v1" "seed" {
  for_each = var.seed_from_database != "" ? local.instances : toset([])

  depends_on = [kubernetes_job_v1.postgres_setup]

  metadata {
    name      = "${var.name}-postgres-seed"
    namespace = var.setup_namespace
    labels    = merge(var.tags, { app = var.name })
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = merge(var.tags, { app = var.name, job = "${var.name}-postgres-seed" })
      }

      spec {
        restart_policy = "Never"

        container {
          name  = "seed"
          image = "postgres:18.6-alpine"

          env {
            name = "SETUP_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres_setup_env[each.key].metadata[0].name
                key  = "SETUP_PASSWORD"
              }
            }
          }

          env {
            name = "SUPERUSER_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.postgres_superuser_secret
                key  = "POSTGRES_PASSWORD"
              }
            }
          }

          command = ["sh", "-ec"]
          args = [
            join("\n", [
              "tables=$(PGPASSWORD=\"$SETUP_PASSWORD\" psql -h ${local.pg} -U ${local.db} -d ${local.db} -tAc \"SELECT count(*) FROM pg_tables WHERE schemaname = 'public'\")",
              "if [ \"$tables\" != 0 ]; then echo \"${local.db} already has $tables tables; not seeding\"; exit 0; fi",
              "PGPASSWORD=\"$SUPERUSER_PASSWORD\" pg_dump -h ${local.pg} -U postgres --no-owner --no-acl ${var.seed_from_database} | PGPASSWORD=\"$SETUP_PASSWORD\" psql -h ${local.pg} -U ${local.db} -d ${local.db} -v ON_ERROR_STOP=1 -q",
              "echo \"seeded ${local.db} from ${var.seed_from_database}\"",
            ]),
          ]

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
}

# ── Runtime Secret (chart `existingSecret` contract) ────────────────────────
# All values are TF-generated or composed from platform-internal creds — no
# operator-supplied secrets here (provider API keys are entered later in the
# console and encrypted app-side with the master key).

resource "random_bytes" "master_key" {
  # Only whether a key was passed is used here, never the key itself.
  for_each = nonsensitive(var.master_key == "") ? local.instances : toset([])
  length   = 32
}

resource "random_bytes" "session_key" {
  for_each = local.instances
  length   = 32
}

resource "random_password" "admin" {
  for_each = local.instances

  length  = 24
  special = false
}

# Own Redis identity instead of the shared `default` superuser: the
# gateway's keys all live under `air:` (usage counters, locks, login
# throttling). The ACL keeper in the Redis namespace applies this line to
# every node (see modules/redis). ACLs cannot limit a user to one database
# index, so instances on different `redis_db` indexes are kept apart by
# their URLs, not by the ACL.
resource "random_password" "redis" {
  for_each = local.instances
  length   = 32
  special  = false
}

resource "kubernetes_secret_v1" "redis_acl" {
  for_each = local.instances

  metadata {
    name      = "redis-acl-${var.name}"
    namespace = var.redis_acl_namespace
    labels = merge(var.tags, {
      "app.kubernetes.io/component" = "airllm"
      "platform.local/redis-acl"    = "true"
    })
  }

  data = {
    setuser = "${var.name} on #${sha256(random_password.redis["enabled"].result)} ~air:* &air:* +@all -@dangerous +info"
  }
}

resource "kubernetes_secret_v1" "runtime" {
  for_each = local.instances

  metadata {
    name      = "${var.name}-secrets"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(var.tags, { "app.kubernetes.io/component" = "airllm" })
  }

  data = merge(
    {
      "database-url"   = "postgres://${local.db}:${random_password.db["enabled"].result}@${local.pg}:5432/${local.db}?sslmode=disable"
      "redis-url"      = "redis://${var.name}:${random_password.redis["enabled"].result}@${var.redis_host}:${var.redis_port}/${var.redis_db}"
      "master-key"     = local.master_key
      "session-key"    = random_bytes.session_key["enabled"].base64
      "admin-password" = random_password.admin["enabled"].result
    },
    # The chart passes this to the pod by secretKeyRef; the pod reads it at
    # start, so a new client secret (a recreated Zitadel app) needs a restart.
    var.oidc == null ? {} : { "oidc-client-secret" = var.oidc_client_secret },
  )
}

# ── Argo CD Application (public chart, values inline) ───────────────────────

resource "kubectl_manifest" "application" {
  for_each = local.instances

  depends_on = [
    kubernetes_secret_v1.runtime,
    kubernetes_job_v1.postgres_setup,
    # The app migrates on start; a seed must land first or it would find
    # the migrated tables and skip.
    kubernetes_job_v1.seed,
  ]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = var.name
      namespace  = var.argocd_namespace
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
      labels = merge(var.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = {
      project = "platform"

      source = {
        repoURL        = var.repo_url
        path           = "deploy/helm/airllm"
        targetRevision = var.chart_revision
        helm = {
          # Tracking main: the digests the app repo's CI writes per build.
          valueFiles = var.chart_revision == "main" ? ["../../argocd/values-main.yaml"] : []
          valuesObject = {
            existingSecret = kubernetes_secret_v1.runtime["enabled"].metadata[0].name
            image = {
              repository = "ghcr.io/ipsupport-llc/ipsupport-airllm"
              tag        = var.image_tag
            }
            config = local.config
            app = {
              # The disruption budget keeps a drain from taking every replica
              # at once. Nothing spreads replicas across nodes, so two guard
              # against losing a pod, not necessarily a node.
              replicaCount        = var.replicas
              nodeSelector        = var.node_selector
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
                tag        = var.image_tag # separate artifact — pin explicitly (chart guidance)
              }
              replicaCount = 1
              autoscaling  = { kind = "none" } # single box — scale later via hpa/keda values
            }
            metrics = {
              serviceMonitor = { enabled = true }
              dashboards     = { enabled = var.dashboards_enabled }
              # The chart's tier-quarantine alert. `release` matches the
              # Prometheus rule selector; `alert_source = metric` is what the
              # metric-alert email route matches — it also needs this
              # namespace under `monitoring.metric_alert_email.namespaces`.
              prometheusRule = {
                enabled     = var.prometheus_rule_enabled
                labels      = { release = "kube-prometheus-stack" }
                alertLabels = { severity = "warning", alert_source = "metric" }
              }
            }
            # Off unless an SA to impersonate is configured, and then the only
            # thing it changes is that the pod gains a cloud identity — the
            # chart renders nothing here when disabled. projectNumber is a
            # STRING on purpose: as a number, YAML round-trips it into
            # scientific notation and the audience STS sees is garbage.
            googleWorkloadIdentity = {
              enabled        = local.wif_enabled
              projectNumber  = local.wif.project_number
              poolId         = local.wif.pool_id
              providerId     = local.wif.provider_id
              serviceAccount = var.google_service_account
            }
          }
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.namespace
      }

      syncPolicy = {
        automated   = { prune = true, selfHeal = true }
        syncOptions = ["CreateNamespace=false"]
      }
    }
  })

  lifecycle {
    precondition {
      condition     = !local.wif_enabled || local.wif.project_number != ""
      error_message = "google_service_account is set (${var.google_service_account}) but gcp_wif_audience is empty or malformed. It must read //iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER> — the chart derives the pool coordinates from it. Either set it or drop google_service_account."
    }
    precondition {
      condition     = var.oidc == null || var.hostname != ""
      error_message = "oidc needs a hostname: the OIDC redirect URL is https://<hostname>/auth/callback."
    }
    precondition {
      condition     = var.oidc == null || var.oidc_client_secret != ""
      error_message = "oidc is set but oidc_client_secret is empty."
    }
  }
}

# ── Direct exposure: unproxied A record + LE cert + IngressRoute ─────────────

resource "cloudflare_dns_record" "this" {
  for_each = var.cloudflare_zone_id != "" ? local.routed : toset([])

  zone_id = var.cloudflare_zone_id
  name    = var.hostname
  type    = "A"
  content = var.public_ip
  ttl     = 300
  proxied = false
  comment = "AirLLM console/API — direct to traefik_public VIP (no CF proxy)"
}

resource "kubectl_manifest" "certificate" {
  for_each = local.routed

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "${var.name}-tls"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    }
    spec = {
      secretName = "${var.name}-tls"
      issuerRef  = { kind = "ClusterIssuer", name = "letsencrypt-production" }
      dnsNames   = [var.hostname]
    }
  })
}

# Plain-HTTP hits (e.g. a client configured with http://…/v1) otherwise fall
# through to the cluster 404 fallback — redirect them to https instead.
resource "kubectl_manifest" "redirect_middleware" {
  for_each = local.routed

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "${var.name}-https-redirect"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    }
    spec = {
      redirectScheme = { scheme = "https", permanent = true }
    }
  })
}

resource "kubectl_manifest" "ingressroute_web" {
  for_each = local.routed

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "${var.name}-web-redirect"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match       = "Host(`${var.hostname}`)"
        kind        = "Rule"
        middlewares = [{ name = "${var.name}-https-redirect" }]
        services    = [{ name = var.name, port = 8080 }] # unreachable past the redirect; Traefik requires a service
      }]
    }
  })
}

resource "kubectl_manifest" "ingressroute" {
  for_each = local.routed

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = var.name
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`${var.hostname}`)"
        kind  = "Rule"
        services = [{
          name = var.name # the chart's Service is named after the release
          port = 8080
        }]
      }]
      tls = { secretName = "${var.name}-tls" }
    }
  })
}
