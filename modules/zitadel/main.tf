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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── Inputs ────────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Deploy Zitadel. When false, no resources are created."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace Zitadel lives in. Expected to exist already (root-owned `platform`). Null when disabled."
  type        = string
  default     = null
}

variable "image" {
  description = "Zitadel main container image. v4 dropped the embedded Angular login form — the login UI now lives in the separate Next.js sidecar (`login_image`). Together with the FirstInstance machine-user PAT we bootstrap to disk, the chicken-and-egg of provisioning login-v2's service account vanishes."
  type        = string
  default     = "ghcr.io/zitadel/zitadel:v4.14.0"
}

variable "login_image" {
  description = "Zitadel Login UI v2 sidecar image. Versioned independently from the main server (separate repo: zitadel/typescript). v3.0.1 (latest tagged release) ships without the wait-for-token-file entrypoint that newer commits added — the `:main` rolling tag has it. Pin to `:main` until the next semver release is cut."
  type        = string
  default     = "ghcr.io/zitadel/login:main"
}

variable "postgres_host" {
  description = "In-cluster Postgres hostname (e.g. postgres.platform.svc.cluster.local)."
  type        = string
}

variable "postgres_superuser_secret" {
  description = "Name of the Secret (in this namespace) holding the Postgres superuser password. Used by the bootstrap Job to CREATE DATABASE / CREATE ROLE."
  type        = string
}

variable "external_domain" {
  description = "Public hostname Zitadel issues tokens for (e.g. id.example.com). Sets ExternalDomain — every OIDC issuer URL, redirect callback and email link references this host. Changing it later invalidates existing client redirect URIs."
  type        = string
}

variable "first_admin_email" {
  description = "Email address of the bootstrap human admin (lands on the master instance). Pre-verified so login works without SMTP."
  type        = string
}

variable "first_admin_username" {
  description = "Username for the bootstrap human admin."
  type        = string
  default     = "zitadel-admin"
}

variable "login_policy" {
  description = <<-EOT
    Default Login Policy applied at FIRSTINSTANCE bootstrap. Sets the
    instance-wide gate for self-service registration, external IDP
    federation, and username/password login. Secure default: registration
    OFF (operator decides who joins; nobody self-onboards), Google/SAML
    federation ON (so wired IDPs work), username/password ON (so the
    bootstrap admin can log in).

    NOTE: FIRSTINSTANCE config takes effect only on the very first boot
    against an empty database. Tweaking these values on an existing
    instance won't propagate without a DB drop OR the (deferred)
    TF-driven `zitadel_default_login_policy` resource.
  EOT
  type = object({
    allow_register          = optional(bool, false)
    allow_external_idp      = optional(bool, true)
    allow_username_password = optional(bool, true)
  })
  default = {}
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  db_name = "platform_zitadel"
  db_user = "platform_zitadel"
}

# ── Secrets: masterkey, db password, initial admin password ───────────────────

# Zitadel uses this 32-char key to encrypt secrets at rest in Postgres
# (client_secret, smtp_password, refresh tokens, etc). Lose it and the
# DB is unreadable — but bootstrap is destroy-and-recreate by design,
# so we generate fresh and let TF state carry it.
resource "random_password" "masterkey" {
  for_each = local.instances

  length  = 32
  special = false
}

resource "random_password" "db" {
  for_each = local.instances

  length  = 32
  special = false
}

# Initial human admin password. Zitadel's default password policy
# requires upper + lower + digit + symbol, ≥ 8 chars. We satisfy with
# wide margins so the operator can paste it without surprise.
resource "random_password" "admin" {
  for_each = local.instances

  length           = 24
  override_special = "!@#%&*+_-"
  min_special      = 2
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

resource "kubernetes_secret_v1" "zitadel" {
  for_each = local.instances

  metadata {
    name      = "zitadel"
    namespace = var.namespace
  }

  data = {
    masterkey      = random_password.masterkey["enabled"].result
    db_password    = random_password.db["enabled"].result
    admin_password = random_password.admin["enabled"].result
  }
}

# ── Postgres provisioning Job ─────────────────────────────────────────────────

# Creates the `platform_zitadel` database + role with full privileges
# in the `public` schema. Mirrors the per-tenant pattern in
# modules/project — DO-block-style idempotent SQL so re-applies are
# safe and the DB survives `terraform destroy` → re-apply.
resource "kubernetes_job_v1" "postgres_setup" {
  for_each = local.instances

  metadata {
    name      = "zitadel-postgres-setup"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "zitadel"
    }
  }

  spec {
    backoff_limit = 3

    template {
      metadata {
        labels = { job = "zitadel-postgres-setup" }
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

          # `PGPASSWORD` → picked up by psql automatically. The
          # superuser Secret emits POSTGRES_PASSWORD — alias it.
          env {
            name  = "PGPASSWORD"
            value = "$(POSTGRES_PASSWORD)"
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "256Mi" }
          }

          command = [
            "sh", "-c",
            join(" && ", [
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = '${local.db_name}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE DATABASE \\\"${local.db_name}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -tc \"SELECT 1 FROM pg_roles WHERE rolname = '${local.db_user}'\" | grep -q 1 || psql -h ${var.postgres_host} -U postgres -c \"CREATE ROLE \\\"${local.db_user}\\\" WITH LOGIN PASSWORD '${random_password.db["enabled"].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"ALTER ROLE \\\"${local.db_user}\\\" WITH PASSWORD '${random_password.db["enabled"].result}'\"",
              "psql -h ${var.postgres_host} -U postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"${local.db_name}\\\" TO \\\"${local.db_user}\\\"\"",
              "psql -h ${var.postgres_host} -U postgres -d ${local.db_name} -c \"GRANT ALL ON SCHEMA public TO \\\"${local.db_user}\\\"\"",
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

# ── Deployment ────────────────────────────────────────────────────────────────

# Single replica — Postgres backing store is also single-replica, so
# scaling Zitadel out gains nothing here. Stateless workload (all state
# in Postgres) so a Deployment, not a StatefulSet.
resource "kubernetes_deployment_v1" "zitadel" {
  for_each = local.instances

  depends_on = [kubernetes_job_v1.postgres_setup]

  metadata {
    name      = "zitadel"
    namespace = var.namespace
    labels    = { app = "zitadel" }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "zitadel" }
    }

    # Recreate strategy — the binary owns the schema and we don't want
    # two versions racing migrations against the same DB.
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = { app = "zitadel" }
      }

      spec {
        # k8s otherwise injects `ZITADEL_PORT=tcp://<svc-ip>:8080`
        # (legacy docker-link compatibility env vars for every Service
        # in the same namespace). Zitadel reads `ZITADEL_PORT` as its
        # own listen-port config and dies parsing "tcp://..." as a
        # uint. Disable the auto-injected vars; we set every config
        # value explicitly anyway.
        enable_service_links = false

        container {
          name  = "zitadel"
          image = var.image

          # `start-from-init` runs schema setup + first-instance
          # bootstrap on the very first start, then runs the server.
          # Idempotent: subsequent boots skip already-applied work.
          # `--tlsMode external` because TLS terminates at Cloudflare's
          # edge; the pod listens plain HTTP behind Traefik.
          args = [
            "start-from-init",
            "--masterkeyFromEnv",
            "--tlsMode", "external",
            "--steps", "/etc/zitadel/steps.yaml",
          ]

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name = "ZITADEL_MASTERKEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.zitadel["enabled"].metadata[0].name
                key  = "masterkey"
              }
            }
          }

          # Public-facing identity — every issuer URL, redirect URI,
          # and email link is built from these three.
          env {
            name  = "ZITADEL_EXTERNALDOMAIN"
            value = var.external_domain
          }
          env {
            name  = "ZITADEL_EXTERNALPORT"
            value = "443"
          }
          env {
            name  = "ZITADEL_EXTERNALSECURE"
            value = "true"
          }

          # Database connection. USER = `platform_zitadel` (least
          # privilege, runtime DML). ADMIN = postgres superuser, used
          # only by `start-from-init` to CREATE ROLE for Zitadel's
          # internal `eventstore`/`projections` accounts on first
          # boot — Zitadel insists on owning that role lifecycle so
          # we can't pre-create them, and our pre-provisioned
          # platform_zitadel role lacks CREATEROLE on purpose.
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_HOST"
            value = var.postgres_host
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_PORT"
            value = "5432"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_DATABASE"
            value = local.db_name
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_USERNAME"
            value = local.db_user
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.zitadel["enabled"].metadata[0].name
                key  = "db_password"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE"
            value = "disable"
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME"
            value = "postgres"
          }
          env {
            name = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.postgres_superuser_secret
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE"
            value = "disable"
          }

          # Sonyflake (distributed ID generator) needs a stable
          # machine identifier. Defaults try (1) RFC1918 private IP
          # which fails on k3s pod CIDR detection here, then (2) GCP
          # metadata webhook which obviously isn't reachable. Disable
          # both and use the pod hostname — k8s already guarantees
          # uniqueness per Pod, which is exactly Sonyflake's contract.
          env {
            name  = "ZITADEL_MACHINE_IDENTIFICATION_PRIVATEIP_ENABLED"
            value = "false"
          }
          env {
            name  = "ZITADEL_MACHINE_IDENTIFICATION_HOSTNAME_ENABLED"
            value = "true"
          }
          env {
            name  = "ZITADEL_MACHINE_IDENTIFICATION_WEBHOOK_ENABLED"
            value = "false"
          }

          # First-instance bootstrap — only consulted on the very
          # first `start-from-init` run; subsequent boots ignore.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME"
            value = var.first_admin_username
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS"
            value = var.first_admin_email
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED"
            value = "true"
          }
          env {
            name = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.zitadel["enabled"].metadata[0].name
                key  = "admin_password"
              }
            }
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED"
            value = "false"
          }

          # Machine user + Personal Access Token, generated at first
          # boot and written to PatPath inside the container. The
          # `pat-broker` sidecar below picks the file up and pushes
          # the token into a k8s Secret (`zitadel-tf-pat`) so the TF
          # Zitadel provider can authenticate without an operator
          # ever touching the UI. Far-future expiry — the PAT is
          # platform infrastructure, not a user credential.
          # Default Login Policy — set at FIRSTINSTANCE so a fresh
          # bootstrap lands secure (no public registration). Tweaks
          # via these envs against an existing instance don't take —
          # FIRSTINSTANCE config is consulted exactly once.
          env {
            name  = "ZITADEL_FIRSTINSTANCE_LOGINPOLICY_ALLOWREGISTER"
            value = tostring(var.login_policy.allow_register)
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_LOGINPOLICY_ALLOWEXTERNALIDP"
            value = tostring(var.login_policy.allow_external_idp)
          }
          env {
            name  = "ZITADEL_FIRSTINSTANCE_LOGINPOLICY_ALLOWUSERNAMEPASSWORD"
            value = tostring(var.login_policy.allow_username_password)
          }

          # Machine user + PAT lifted to file via the steps.yaml
          # ConfigMap mounted at /etc/zitadel/steps.yaml. Plain envs
          # don't expose PatPath — that knob lives only on the
          # FirstInstance section consumed by `--steps`.
          volume_mount {
            name       = "pat-output"
            mount_path = "/var/zitadel/secrets"
          }
          volume_mount {
            name       = "steps"
            mount_path = "/etc/zitadel"
            read_only  = true
          }

          # Go binary, idle ~50-100m CPU. 1 CPU limit covers a
          # spike of concurrent OIDC token exchanges without
          # CPU-throttling. Fits the platform-budget ResourceQuota
          # (12 CPU total) with room because Ollama dropped to a 2
          # CPU limit once inference moved to the Arc B50 GPU.
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }

          # First boot runs the full migration set; allow up to 5min
          # before the kubelet starts killing on liveness.
          startup_probe {
            http_get {
              path = "/debug/healthz"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 60
            timeout_seconds   = 3
          }

          liveness_probe {
            http_get {
              path = "/debug/healthz"
              port = 8080
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 3
          }

          readiness_probe {
            http_get {
              path = "/debug/ready"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 3
            timeout_seconds   = 3
          }
        }

        # PAT broker. Watches the PatPath for the FIRSTINSTANCE-
        # generated machine-user token, then creates/updates the
        # `zitadel-tf-pat` Secret so the TF Zitadel provider can pick
        # it up via `data "kubernetes_resources"` on the next apply.
        # Uses the dedicated `zitadel-pat-broker` ServiceAccount which
        # only has Secret create/patch in this namespace.
        container {
          name  = "pat-broker"
          image = "bitnami/kubectl:latest"

          command = ["/bin/bash", "-c"]
          args = [
            <<-EOT
            set -euo pipefail
            echo "pat-broker: waiting for PAT file..."
            until [ -s /var/zitadel/secrets/pat ]; do sleep 2; done
            TOKEN=$(cat /var/zitadel/secrets/pat)
            echo "pat-broker: PAT captured ($${#TOKEN} chars), syncing Secret..."
            kubectl create secret generic zitadel-tf-pat \
              --namespace="${var.namespace}" \
              --from-literal=access_token="$TOKEN" \
              --dry-run=client -o yaml \
              | kubectl apply -f -
            echo "pat-broker: Secret synced, idling."
            sleep infinity
            EOT
          ]

          # bitnami/kubectl is lean (Alpine + the kubectl binary)
          # but `kubectl apply` spikes memory parsing the API
          # discovery cache on first run. 64Mi was too tight (OOM
          # exit-137 on first apply); 192Mi has comfortable headroom.
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { cpu = "100m", memory = "192Mi" }
          }

          volume_mount {
            name       = "pat-output"
            mount_path = "/var/zitadel/secrets"
          }
        }

        # Login UI v2 — Next.js app, served at /ui/v2/login. Runs as
        # a sidecar so it can authenticate to the main Zitadel API
        # over loopback (http://localhost:8080) and read the same
        # FIRSTINSTANCE-bootstrapped PAT file the pat-broker harvests.
        # Traefik routes /ui/v2/login/* to the `zitadel-login`
        # Service emitted below.
        container {
          name  = "login"
          image = var.login_image

          # The published login image expects ZITADEL_SERVICE_USER_TOKEN
          # to be set as an env var. Per upstream comments the image
          # *should* convert _TOKEN_FILE → _TOKEN at startup, but neither
          # v3.0.1 nor :main does it (no entrypoint wrapper, server.js
          # boots straight from PID 1). Do the conversion ourselves —
          # block until the FIRSTINSTANCE-bootstrapped login-client.pat
          # file appears, read it, then exec the upstream entrypoint.
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            until [ -s /var/zitadel/secrets/login-client.pat ]; do
              echo "login: waiting for login-client.pat..."
              sleep 2
            done
            export ZITADEL_SERVICE_USER_TOKEN="$(cat /var/zitadel/secrets/login-client.pat)"
            echo "login: token loaded ($${#ZITADEL_SERVICE_USER_TOKEN} chars), starting next-server..."
            exec node apps/login/server.js
            EOT
          ]

          port {
            name           = "http"
            container_port = 3000
          }

          env {
            name  = "ZITADEL_API_URL"
            value = "http://localhost:8080"
          }

          # login-v2 talks to the main Zitadel API over loopback, but
          # Zitadel routes incoming requests to the right instance by
          # matching the Host header against the instance's configured
          # ExternalDomain. `localhost:8080` doesn't match → "Instance
          # not found". Override the outgoing Host header so gRPC
          # calls land on the right instance. (This is the canonical
          # CUSTOM_REQUEST_HEADERS pattern from the official Helm
          # chart — `Host:<ExternalDomain>` exactly.)
          env {
            name  = "CUSTOM_REQUEST_HEADERS"
            value = "Host:${var.external_domain}"
          }
          # Surface verification + customisation flags as defaults;
          # operators can extend by mounting a sidecar-side .env.
          env {
            name  = "EMAIL_VERIFICATION"
            value = "false"
          }
          env {
            name  = "NEXT_PUBLIC_BASE_PATH"
            value = "/ui/v2/login"
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }

          startup_probe {
            http_get {
              path = "/ui/v2/login"
              port = 3000
            }
            period_seconds    = 5
            failure_threshold = 30
            timeout_seconds   = 3
          }

          liveness_probe {
            http_get {
              path = "/ui/v2/login"
              port = 3000
            }
            period_seconds    = 10
            failure_threshold = 3
            timeout_seconds   = 3
          }

          readiness_probe {
            http_get {
              path = "/ui/v2/login"
              port = 3000
            }
            period_seconds    = 5
            failure_threshold = 3
            timeout_seconds   = 3
          }

          volume_mount {
            name       = "pat-output"
            mount_path = "/var/zitadel/secrets"
            read_only  = true
          }
        }

        service_account_name = kubernetes_service_account_v1.pat_broker["enabled"].metadata[0].name

        volume {
          name = "pat-output"
          empty_dir {}
        }

        volume {
          name = "steps"
          config_map {
            name = kubernetes_config_map_v1.steps["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Steps ConfigMap (FirstInstance setup) ─────────────────────────────────────
#
# Loaded via `--steps /etc/zitadel/steps.yaml` on the Zitadel
# container. The DefaultInstance env-var path does NOT expose PatPath
# / MachineKeyPath — those live only in the steps file. So we mount a
# minimal steps.yaml whose only job is to set FirstInstance.PatPath +
# FirstInstance.Org.Machine.Machine + Pat so a PAT lands in a file
# the sidecar can lift into a Secret.

resource "kubernetes_config_map_v1" "steps" {
  for_each = local.instances

  metadata {
    name      = "zitadel-steps"
    namespace = var.namespace
  }

  data = {
    "steps.yaml" = yamlencode({
      FirstInstance = {
        # tf-platform machine user PAT — for the TF Zitadel provider
        # (auto-provisioning kind:app components) and any other
        # external admin tooling.
        PatPath = "/var/zitadel/secrets/pat"
        # login-client machine user PAT — v4 wants the login UI v2
        # sidecar to authenticate as its OWN dedicated service
        # account, not as the platform's general admin user. Two
        # files, two service accounts, separate blast radius.
        LoginClientPatPath = "/var/zitadel/secrets/login-client.pat"
        Org = {
          Machine = {
            Machine = {
              Username = "tf-platform"
              Name     = "tf-platform"
            }
            Pat = {
              ExpirationDate = "2099-12-31T00:00:00Z"
            }
          }
          LoginClient = {
            Machine = {
              Username = "login-client"
              Name     = "login-client"
            }
            Pat = {
              ExpirationDate = "2099-12-31T00:00:00Z"
            }
          }
        }
      }
    })
  }
}

# ── Default Login Policy reconciler ───────────────────────────────────────────
#
# v4 dropped LoginPolicy from FirstInstance steps schema, so seeding
# the policy at bootstrap doesn't work — the instance comes up with
# Zitadel's built-in defaults (registration ON). The official TF
# provider's zitadel_default_login_policy resource WOULD be the right
# answer, but it speaks gRPC over HTTP/2 and our cloudflared → Traefik
# path is HTTP/1.1 by default — provider hits 403/HTML on every call
# (zitadel/terraform-provider-zitadel#242). Until we wire end-to-end
# h2c (separate PR), reconcile the policy via a TF-managed PUT to
# /admin/v1/policies/login. PAT comes from the FIRSTINSTANCE-bootstrapped
# `zitadel-tf-pat` Secret. Idempotent (PUT), re-runs whenever any of
# the triggers change.

resource "null_resource" "default_login_policy" {
  for_each = local.instances

  depends_on = [kubernetes_deployment_v1.zitadel]

  triggers = {
    allow_register          = tostring(var.login_policy.allow_register)
    allow_external_idp      = tostring(var.login_policy.allow_external_idp)
    allow_username_password = tostring(var.login_policy.allow_username_password)
    external_domain         = var.external_domain
    namespace               = var.namespace
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      ALLOW_REGISTER  = self.triggers.allow_register
      ALLOW_EXTERNAL  = self.triggers.allow_external_idp
      ALLOW_USERPW    = self.triggers.allow_username_password
      EXTERNAL_DOMAIN = self.triggers.external_domain
      NAMESPACE       = self.triggers.namespace
    }
    command = <<-EOT
      set -euo pipefail

      # Wait up to ~3min for the FIRSTINSTANCE-bootstrapped PAT Secret.
      # On a fresh apply the sidecar needs Zitadel main to boot before
      # it can write the Secret, so kubectl get may miss it the first
      # second or three.
      PAT=""
      for i in $(seq 1 90); do
        PAT="$(kubectl get secret zitadel-tf-pat -n "$NAMESPACE" -o jsonpath='{.data.access_token}' 2>/dev/null | base64 -d || true)"
        [[ -n "$PAT" ]] && break
        sleep 2
      done
      if [[ -z "$PAT" ]]; then
        echo "default_login_policy: zitadel-tf-pat Secret never appeared, giving up" >&2
        exit 1
      fi

      # Wait for the issuer URL to actually answer (Zitadel migrations
      # can take a minute on a fresh DB).
      for i in $(seq 1 90); do
        if curl -fsS -o /dev/null "https://$EXTERNAL_DOMAIN/.well-known/openid-configuration"; then
          break
        fi
        sleep 2
      done

      # PUT the policy. Zitadel returns 400 with code 9 + body
      # "Default Login Policy has not been changed" when the request
      # matches current state — treat that as a successful no-op.
      RESP=$(curl -sS -w "\n%%{http_code}" -X PUT \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -d "{\"allowRegister\":$ALLOW_REGISTER,\"allowExternalIdp\":$ALLOW_EXTERNAL,\"allowUsernamePassword\":$ALLOW_USERPW,\"passwordlessType\":\"PASSWORDLESS_TYPE_ALLOWED\",\"ignoreUnknownUsernames\":true,\"passwordCheckLifetime\":\"864000s\",\"externalLoginCheckLifetime\":\"864000s\",\"mfaInitSkipLifetime\":\"2592000s\",\"secondFactorCheckLifetime\":\"64800s\",\"multiFactorCheckLifetime\":\"43200s\",\"forceMfa\":false,\"forceMfaLocalOnly\":false,\"hidePasswordReset\":false,\"allowDomainDiscovery\":false,\"disableLoginWithEmail\":false,\"disableLoginWithPhone\":false}" \
        "https://$EXTERNAL_DOMAIN/admin/v1/policies/login")
      CODE=$(echo "$RESP" | tail -n1)
      BODY=$(echo "$RESP" | head -n -1)
      if [[ "$CODE" == "200" ]]; then
        echo "default_login_policy: updated (allowRegister=$ALLOW_REGISTER allowExternalIdp=$ALLOW_EXTERNAL allowUsernamePassword=$ALLOW_USERPW)"
      elif echo "$BODY" | grep -q "has not been changed"; then
        echo "default_login_policy: already matches (allowRegister=$ALLOW_REGISTER allowExternalIdp=$ALLOW_EXTERNAL allowUsernamePassword=$ALLOW_USERPW)"
      else
        echo "default_login_policy: PUT failed with HTTP $CODE: $BODY" >&2
        exit 1
      fi
    EOT
  }
}

# ── PAT broker RBAC ───────────────────────────────────────────────────────────
#
# Minimal scope: the sidecar can only create/patch Secrets in its own
# namespace. Targeted further to the single Secret name with a
# resource_names limiter would be cleaner but RBAC's resourceNames
# blocks `create` (only post-creation verbs honour it), so namespace
# scope is the floor.

resource "kubernetes_service_account_v1" "pat_broker" {
  for_each = local.instances

  metadata {
    name      = "zitadel-pat-broker"
    namespace = var.namespace
  }
}

resource "kubernetes_role_v1" "pat_broker" {
  for_each = local.instances

  metadata {
    name      = "zitadel-pat-broker"
    namespace = var.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["create", "get", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "pat_broker" {
  for_each = local.instances

  metadata {
    name      = "zitadel-pat-broker"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.pat_broker["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.pat_broker["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "zitadel" {
  for_each = local.instances

  metadata {
    name      = "zitadel"
    namespace = var.namespace
    labels    = { app = "zitadel" }
  }

  spec {
    selector = { app = "zitadel" }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Separate Service so Traefik can path-route `/ui/v2/login/*` to the
# login-v2 sidecar (port 3000) while keeping the rest of the host on
# the main Zitadel API (port 8080).
resource "kubernetes_service_v1" "zitadel_login" {
  for_each = local.instances

  metadata {
    name      = "zitadel-login"
    namespace = var.namespace
    labels    = { app = "zitadel" }
  }

  spec {
    selector = { app = "zitadel" }

    port {
      name        = "http"
      port        = 3000
      target_port = 3000
    }
  }
}

# Path-prefix IngressRoute for the login-v2 sidecar.
#
# The default IngressRoute that modules/project emits for the zitadel
# `kind: external` component matches Host(<external_domain>) only. We
# layer a higher-priority route on top: same host PLUS PathPrefix
# `/ui/v2/login` → zitadel-login Service. Traefik's default router
# scoring picks the longer match (Host AND Path) over the
# Host-only rule for any URL under /ui/v2/login/*, so login traffic
# lands on the sidecar and everything else stays on the main API.

resource "kubectl_manifest" "login_ingress_route" {
  for_each = local.instances

  depends_on = [kubernetes_deployment_v1.zitadel, kubernetes_service_v1.zitadel_login]

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "zitadel-login"
      namespace = var.namespace
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match = "Host(`${var.external_domain}`) && PathPrefix(`/ui/v2/login`)"
        kind  = "Rule"
        services = [{
          name      = "zitadel-login"
          namespace = var.namespace
          port      = 3000
        }]
      }]
    }
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Namespace where Zitadel runs, or null if disabled."
}

output "service_name" {
  value       = one([for s in kubernetes_service_v1.zitadel : s.metadata[0].name])
  description = "In-cluster Service name for Zitadel."
}

output "host" {
  value       = one([for s in kubernetes_service_v1.zitadel : "${s.metadata[0].name}.${var.namespace}.svc.cluster.local"])
  description = "In-cluster FQDN for Zitadel."
}

output "port" {
  value       = one([for s in kubernetes_service_v1.zitadel : s.spec[0].port[0].port])
  description = "Service port (HTTP, plain — TLS terminates at Cloudflare)."
}

output "external_domain" {
  value       = var.enabled ? var.external_domain : null
  description = "Public hostname Zitadel issues tokens for."
}

output "admin_username" {
  value       = var.enabled ? var.first_admin_username : null
  description = "Bootstrap human admin username — only meaningful right after first apply."
}

output "admin_password" {
  value       = one([for p in random_password.admin : p.result])
  sensitive   = true
  description = "Bootstrap human admin password. Change in the UI on first login. Only re-emitted if the random_password resource is replaced."
}

