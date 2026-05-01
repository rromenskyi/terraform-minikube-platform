terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# =============================================================================
# Vault community — Phase 0: brings the server up + auto-unseals + emits root
# token to a TF-managed Secret. No KV mounts, no auth methods, no policies.
# =============================================================================
#
# Phase 0 success: `services.vault.enabled: true` brings up a working
# Vault you can log into in the UI as the root user (token from
# `terraform output -raw vault_root_token`). Phase 1 (deferred PR)
# wires the Zitadel JWT auth method + admin/operator policies. Phase
# 2 introduces the Vault Secrets Operator + first migrated secret.
# Phase 3 bulk-migrates the cheatsheet-bound TF outputs.
#
# Storage: built-in raft single-node (no external Postgres/Consul).
# RocksDB-style on-disk store. hostPath PV survives pod replace and
# `./tf bootstrap-k3s` (same trade-off Stalwart makes for its data
# dir).
#
# Auto-unseal flow:
#   1. TF creates an empty `vault-bootstrap` Secret up front so the
#      pod's secret-volume mount has somewhere to land at create time.
#   2. The StatefulSet's `vault` container starts, server boots
#      sealed (raft init + listener up, no unseal yet).
#   3. `kubernetes_job_v1.init` runs (depends_on the StatefulSet) and
#      calls `POST /v1/sys/init` with `secret_shares=1, secret_threshold=1`
#      (single-key threshold — this is a single-operator home cluster,
#      shamir doesn't add real safety here). Parses the response JSON
#      and `kubectl patch`es the unseal key + root token into the
#      bootstrap Secret.
#   3. The vault container's `postStart` lifecycle hook polls the
#      secret-mounted file at `/vault/bootstrap/unseal-key` for up to
#      five minutes and runs `vault operator unseal` once it appears.
#      Kubelet projects updated Secret data into running pods within
#      ~60s, so the postStart loop converges without a pod restart.
#   4. Subsequent pod restarts (rollout, k8s reschedule, node reboot)
#      hit the same postStart hook with the Secret already populated
#      → unseal completes within the first poll, no operator action.

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "enabled" {
  description = "Deploy Vault. When false, no resources are created."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Vault lives in. Expected to exist already (typically `platform`)."
  type        = string
  default     = "platform"
}

variable "hostname" {
  description = "Public hostname Vault answers on (e.g. `vault.example.com`). Used for the IngressRoute Host(...) match (`config/components/vault.yaml` is `kind: external`, the operator's domain yaml supplies the route)."
  type        = string
  default     = ""
}

variable "image" {
  description = "Vault container image. Pin a specific tag — `:latest` would silently pull schema changes between restarts. `hashicorp/vault` is the upstream repo (community edition)."
  type        = string
  default     = "hashicorp/vault:1.18.4"
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PV. Vault's raft storage lands at `<volume_base_path>/<namespace>/vault/data/`. Survives `./tf bootstrap-k3s` on purpose — losing this dir wipes the secret store entirely."
  type        = string
  default     = "/data/vol"
}

variable "memory_request" {
  type    = string
  default = "256Mi"
}

variable "memory_limit" {
  type    = string
  default = "1Gi"
}

variable "cpu_request" {
  type    = string
  default = "100m"
}

variable "cpu_limit" {
  type    = string
  default = "1"
}

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  data_path = "${var.volume_base_path}/${var.namespace}/vault/data"

  # Single-node raft + UI + listener on :8200. `disable_mlock = true`
  # because the pod runs without IPC_LOCK by default — securing memory
  # pages from being swapped is an OS-level concern, not Vault's.
  config_hcl = <<-HCL
    ui = true
    disable_mlock = true

    storage "raft" {
      path    = "/vault/data"
      node_id = "vault-0"
    }

    listener "tcp" {
      address     = "0.0.0.0:8200"
      tls_disable = "true"
    }

    api_addr     = "http://0.0.0.0:8200"
    cluster_addr = "https://0.0.0.0:8201"
  HCL
}

# -----------------------------------------------------------------------------
# RBAC for the bootstrap-init Job — needs to PATCH the
# `vault-bootstrap` Secret with the init response (unseal key + root
# token). Scoped to the single Secret in the single namespace; no
# cluster-wide privileges.
# -----------------------------------------------------------------------------

resource "kubernetes_service_account_v1" "vault" {
  for_each = local.instances

  metadata {
    name      = "vault"
    namespace = var.namespace
    labels    = { app = "vault" }
  }
}

resource "kubernetes_role_v1" "vault_bootstrap" {
  for_each = local.instances

  metadata {
    name      = "vault-bootstrap"
    namespace = var.namespace
  }

  rule {
    api_groups     = [""]
    resources      = ["secrets"]
    resource_names = ["vault-bootstrap"]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "vault_bootstrap" {
  for_each = local.instances

  metadata {
    name      = "vault-bootstrap"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.vault_bootstrap["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vault["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

# -----------------------------------------------------------------------------
# Bootstrap Secret — created EMPTY up front so the StatefulSet's
# secret-volume mount has a target at pod create time. The init Job
# patches it with `unseal-key` and `root-token` keys after `vault
# operator init`. `lifecycle { ignore_changes = [data] }` so TF stops
# fighting the Job over the data field on subsequent applies.
# -----------------------------------------------------------------------------

resource "kubernetes_secret_v1" "vault_bootstrap" {
  for_each = local.instances

  metadata {
    name      = "vault-bootstrap"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "vault"
    }
  }

  # Placeholder keys — the init Job overwrites both with the real
  # values from /v1/sys/init. Empty strings on first apply are fine;
  # the postStart unseal loop polls until the file is non-empty.
  data = {
    "unseal-key" = ""
    "root-token" = ""
  }

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_config_map_v1" "vault_config" {
  for_each = local.instances

  metadata {
    name      = "vault-config"
    namespace = var.namespace
  }

  data = {
    "config.hcl" = local.config_hcl
  }
}

# -----------------------------------------------------------------------------
# hostPath storage for /vault/data (raft state).
# -----------------------------------------------------------------------------

resource "kubernetes_persistent_volume_v1" "vault" {
  for_each = local.instances

  metadata {
    name = "vault-data"
  }

  spec {
    capacity = {
      storage = "5Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = local.data_path
        type = "DirectoryOrCreate"
      }
    }

    claim_ref {
      namespace = var.namespace
      name      = "vault-data"
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "vault" {
  for_each = local.instances

  metadata {
    name      = "vault-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.vault["enabled"].metadata[0].name

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# StatefulSet — single replica, raft single-node, postStart auto-unseal.
# -----------------------------------------------------------------------------

resource "kubernetes_stateful_set_v1" "vault" {
  for_each = local.instances

  depends_on = [kubernetes_secret_v1.vault_bootstrap]

  # Phase 0 chicken-and-egg: the init Job depends on this StatefulSet
  # existing AND being reachable, but the pod only becomes Ready after
  # the init Job patches the bootstrap Secret AND the postStart hook
  # runs unseal. With wait_for_rollout=true, TF blocks here forever.
  # Default is true; flip false so TF moves past the StatefulSet to
  # the init Job, which then unblocks readiness via the postStart
  # path.
  wait_for_rollout = false

  metadata {
    name      = "vault"
    namespace = var.namespace
    labels    = { app = "vault" }
  }

  spec {
    service_name = "vault"
    replicas     = 1

    selector {
      match_labels = { app = "vault" }
    }

    template {
      metadata {
        labels = { app = "vault" }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.vault["enabled"].metadata[0].name

        # k8s auto-injects `<SVC>_PORT=tcp://...` per Service in the
        # namespace. Some Vault config paths read `VAULT_PORT` and
        # crash on a non-numeric value. Cheap insurance — same logic
        # we use for Zitadel/Stalwart/Roundcube.
        enable_service_links = false

        container {
          name              = "vault"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          args = ["server", "-config=/vault/config/config.hcl"]

          # IPC_LOCK is dropped by `disable_mlock = true` in
          # config.hcl. SETFCAP is dropped because we don't ship
          # binaries.
          security_context {
            capabilities {
              drop = ["ALL"]
            }
            run_as_user                = 100
            run_as_group               = 1000
            run_as_non_root            = true
            allow_privilege_escalation = false
          }

          port {
            name           = "http"
            container_port = 8200
          }
          port {
            name           = "cluster"
            container_port = 8201
          }

          env {
            name  = "VAULT_ADDR"
            value = "http://127.0.0.1:8200"
          }

          # postStart polls the bootstrap-Secret-mounted file for up
          # to ~5min and runs `vault operator unseal` once the key
          # appears. Kubelet projects updated Secret data into running
          # pods within ~60s of the Secret PATCH, so this loop
          # converges without a pod restart on the first apply, and
          # immediately on every subsequent restart.
          lifecycle {
            post_start {
              exec {
                command = [
                  "/bin/sh", "-c",
                  <<-EOT
                  for i in $(seq 1 60); do
                    KEY=$(cat /vault/bootstrap/unseal-key 2>/dev/null || true)
                    if [ -n "$KEY" ]; then
                      vault operator unseal "$KEY" >/dev/null 2>&1 && exit 0
                    fi
                    sleep 5
                  done
                  exit 0
                  EOT
                ]
              }
            }
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }

          # `/v1/sys/health` returns:
          #   200 — initialised + unsealed + active
          #   429 — initialised + unsealed + standby (HA)
          #   501 — not initialised (Phase 0 first start, pre init Job)
          #   503 — sealed (between init and unseal)
          #
          # Permissive query params (`uninitcode=200&sealedcode=200&
          # standbyok=true`) treat 'listener up' as healthy regardless
          # of init/seal state. This is correct for Phase 0 because
          # the bootstrap chain is a chicken-and-egg: the init Job
          # needs to reach the pod (so the pod must be 'Ready' for
          # the Service to route there) BEFORE the pod is initialised
          # or unsealed. With strict probes, init Job timeouts on
          # connection-refused and the apply hangs.
          #
          # Trade-off: for the first ~60-90s of a fresh apply, public
          # traffic landing on the pod sees Vault's "sealed" page.
          # Acceptable for single-operator home cluster where the
          # postStart hook unseals within one kubelet sync interval.
          startup_probe {
            http_get {
              path   = "/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
              port   = 8200
              scheme = "HTTP"
            }
            failure_threshold = 60
            period_seconds    = 5
          }

          liveness_probe {
            http_get {
              path   = "/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
              port   = 8200
              scheme = "HTTP"
            }
            initial_delay_seconds = 60
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path   = "/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"
              port   = 8200
              scheme = "HTTP"
            }
            period_seconds  = 10
            timeout_seconds = 3
          }

          volume_mount {
            name       = "config"
            mount_path = "/vault/config"
            read_only  = true
          }

          volume_mount {
            name       = "data"
            mount_path = "/vault/data"
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/vault/bootstrap"
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.vault_config["enabled"].metadata[0].name
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.vault["enabled"].metadata[0].name
          }
        }

        volume {
          name = "bootstrap"
          secret {
            secret_name = kubernetes_secret_v1.vault_bootstrap["enabled"].metadata[0].name
          }
        }
      }
    }
  }

  # The PVC was created above; don't let the StatefulSet's
  # volumeClaimTemplates conflict with it (we explicitly wire a PVC by
  # name instead of templating one per replica — single-replica home
  # cluster, no benefit from per-replica templates).
}

resource "kubernetes_service_v1" "vault" {
  for_each = local.instances

  metadata {
    name      = "vault"
    namespace = var.namespace
    labels    = { app = "vault" }
  }

  spec {
    selector = { app = "vault" }
    type     = "ClusterIP"

    port {
      name        = "http"
      port        = 8200
      target_port = 8200
    }
  }
}

# -----------------------------------------------------------------------------
# Init Job — runs once per fresh cluster. Polls Vault `/sys/init`
# status; if uninitialised, calls `POST /v1/sys/init`, parses the
# response, kubectl-patches the bootstrap Secret with `unseal-key`
# and `root-token` keys (base64-encoded). Subsequent runs see "already
# initialised" and exit 0 without touching the Secret.
# -----------------------------------------------------------------------------

resource "kubernetes_job_v1" "vault_init" {
  for_each = local.instances

  depends_on = [kubernetes_stateful_set_v1.vault]

  metadata {
    name      = "vault-init"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "vault"
    }
  }

  spec {
    backoff_limit = 5

    template {
      metadata {
        labels = { job = "vault-init" }
      }

      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.vault["enabled"].metadata[0].name

        container {
          name  = "init"
          image = "alpine/k8s:1.31.5"

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "100m", memory = "128Mi" }
          }

          command = [
            "sh", "-c",
            <<-EOT
            set -eu
            URL="http://vault.${var.namespace}.svc.cluster.local:8200"

            echo "[vault-init] waiting for $URL/v1/sys/health..."
            until curl -sf -m 5 -o /dev/null "$URL/v1/sys/health?uninitcode=200&sealedcode=200&standbyok=true"; do
              sleep 3
            done
            echo "[vault-init] vault reachable"

            INIT_STATUS=$(curl -s "$URL/v1/sys/init")
            INITIALISED=$(echo "$INIT_STATUS" | sed -n 's/.*"initialized":\([truefals]*\).*/\1/p')
            echo "[vault-init] initialised=$INITIALISED"

            if [ "$INITIALISED" = "true" ]; then
              # Already initialised — bootstrap Secret should already
              # carry unseal-key + root-token from a previous apply.
              # No-op.
              echo "[vault-init] already initialised — exiting"
              exit 0
            fi

            echo "[vault-init] running operator init"
            INIT=$(curl -s -X POST -H 'Content-Type: application/json' \
              -d '{"secret_shares":1,"secret_threshold":1}' \
              "$URL/v1/sys/init")

            UNSEAL=$(echo "$INIT" | sed -n 's/.*"keys":\["\([^"]*\)".*/\1/p')
            ROOT=$(echo "$INIT" | sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p')

            if [ -z "$UNSEAL" ] || [ -z "$ROOT" ]; then
              echo "[vault-init] ERROR: init response missing keys"
              echo "$INIT"
              exit 1
            fi

            UNSEAL_B64=$(printf '%s' "$UNSEAL" | base64 -w0)
            ROOT_B64=$(printf '%s' "$ROOT" | base64 -w0)

            kubectl patch secret vault-bootstrap -n ${var.namespace} \
              --type='strategic' \
              -p "$(printf '{"data":{"unseal-key":"%s","root-token":"%s"}}' "$UNSEAL_B64" "$ROOT_B64")"

            echo "[vault-init] bootstrap Secret patched — postStart hook will unseal within ~60s"
            EOT
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "enabled" {
  value = var.enabled
}

output "namespace" {
  value = var.namespace
}

output "hostname" {
  value = var.hostname
}

output "service_name" {
  value = var.enabled ? kubernetes_service_v1.vault["enabled"].metadata[0].name : null
}

output "port" {
  value = 8200
}

output "url" {
  description = "Public Vault URL — `terraform output -raw vault_url`."
  value       = var.enabled && var.hostname != "" ? "https://${var.hostname}" : null
}

# Lookup for the bootstrap Secret AFTER the init Job has populated it.
# `data.kubernetes_secret_v1` reads the live Secret on every plan,
# so first apply (Secret empty) yields empty strings; subsequent
# plans pick up the populated values.
data "kubernetes_secret_v1" "vault_bootstrap" {
  for_each = local.instances

  depends_on = [kubernetes_job_v1.vault_init]

  metadata {
    name      = kubernetes_secret_v1.vault_bootstrap["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

output "root_token" {
  description = "Root token emitted by `vault operator init`. Use as break-glass when OIDC is broken or before Phase 1 lands. Read with `terraform output -raw vault_root_token`. Empty until the init Job has run + plan picks up the populated Secret on the second apply (k8s data sources are read at plan time)."
  value       = var.enabled ? try(data.kubernetes_secret_v1.vault_bootstrap["enabled"].data["root-token"], "") : null
  sensitive   = true
}

output "unseal_key" {
  description = "Single unseal key (secret_shares=1, secret_threshold=1 — single-operator home cluster, no shamir benefit). Used by the StatefulSet's postStart hook to auto-unseal on every pod start. Read with `terraform output -raw vault_unseal_key` if you need to unseal manually for some reason."
  value       = var.enabled ? try(data.kubernetes_secret_v1.vault_bootstrap["enabled"].data["unseal-key"], "") : null
  sensitive   = true
}
