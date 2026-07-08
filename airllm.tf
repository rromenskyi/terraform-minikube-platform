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
# Exposure is DIRECT (no Cloudflare tunnel/proxy, operator ruling 2026-07-08):
# unproxied A record → traefik_public VIP → IngressRoute (websecure) with a
# cert-manager Let's Encrypt certificate.

locals {
  airllm = local.platform.services.airllm # defaults + gitignored overrides, normalized in locals.tf

  airllm_instances = local.airllm.enabled ? toset(["enabled"]) : toset([])
  airllm_db        = "airllm"
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
          image = "postgres:16-alpine"

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
              "psql -h ${module.postgres.host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.airllm_db}'\" | grep -q 1 || psql -h ${module.postgres.host} -U postgres -c \"CREATE ROLE \\\"${local.airllm_db}\\\" WITH LOGIN PASSWORD '${random_password.airllm_db["enabled"].result}'\"",
              "psql -h ${module.postgres.host} -U postgres -c \"ALTER ROLE \\\"${local.airllm_db}\\\" WITH PASSWORD '${random_password.airllm_db["enabled"].result}'\"",
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

resource "kubernetes_secret_v1" "airllm" {
  for_each = local.airllm_instances

  metadata {
    name      = "airllm-secrets"
    namespace = kubernetes_namespace_v1.airllm["enabled"].metadata[0].name
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "airllm" })
  }

  data = {
    "database-url"   = "postgres://${local.airllm_db}:${random_password.airllm_db["enabled"].result}@${module.postgres.host}:5432/${local.airllm_db}?sslmode=disable"
    "redis-url"      = "redis://default:${module.redis.default_password}@${module.redis.host}:${module.redis.port}/0"
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
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
      labels = merge(module.platform_label.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = {
      project = "default"

      source = {
        repoURL        = "https://github.com/ipsupport-llc/ipsupport-airllm.git"
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
              replicaCount = 1
              autoscaling  = { enabled = false }
              ingress      = { enabled = false } # platform IngressRoute below owns the route
              # The image's USER is the name `app` (non-numeric), which k8s
              # can't verify against the chart's runAsNonRoot — pin the UID
              # the image is built for (Dockerfile chowns /var/lib/airllm to
              # 10001).
              securityContext = { runAsUser = 10001 }
            }
            dlpBert = { enabled = false } # sidecar image is a separate opt-in (GHCR package still private)
            metrics = {
              serviceMonitor = { enabled = true }
              dashboards     = { enabled = true }
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
