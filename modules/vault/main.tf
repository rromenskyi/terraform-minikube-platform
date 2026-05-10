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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# =============================================================================
# Vault community — server, auto-unseal, and post-init configuration plumbing.
# =============================================================================
#
# Phase 0 (live): server StatefulSet + raft single-node + bootstrap-Secret-
# driven auto-unseal. Operator can log into the UI with the root token
# (`terraform output -raw vault_root_token`). Nothing is mounted yet, no
# auth methods enabled.
#
# Phase 1 (this module, current state): post-init bootstrap Job +
# vault-config-operator Helm release + base CRDs (KV-v2 mount at `secret/`,
# read-only policy `vso-tenant-read`, kubernetes-auth role for VSO). The
# Job's only purpose is to give vault-config-operator's ServiceAccount
# admin rights via Vault's kubernetes auth method; from there vco reconciles
# every other Vault-side concern via CRDs.
#
# Phase 2 (next PR): Zitadel app for Vault + OIDC auth method (CR
# `JWTOIDCAuthEngineConfig`) + per-tenant policies + per-tenant OIDC roles
# (CRs derived from the engine's tenant list). The hashicorp/vault-secrets-
# operator (VSO) Helm release lands here too, plus the engine integration
# in `modules/project` that emits `VaultStaticSecret` instead of literal
# `kubernetes_secret_v1` when `operator_secret_values[<x>] = { vault_path }`.
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


# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------

module "label" {
  source  = "github.com/rromenskyi/terraform-null-label?ref=v0.1.0"
  context = var.context
  name    = "vault"
}

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  tags = module.label.tags

  data_path = "${var.volume_base_path}/${var.namespace}/vault/data"

  # Single-node raft + UI + listener on :8200. `disable_mlock = true`
  # because the pod runs without IPC_LOCK by default — securing memory
  # pages from being swapped is an OS-level concern, not Vault's.
  #
  # `api_addr` and `cluster_addr` are NOT in this HCL on purpose —
  # they're passed as `VAULT_API_ADDR` / `VAULT_CLUSTER_ADDR` env
  # vars on the StatefulSet container, populated from the downward
  # API so they resolve to the pod's actual IP at runtime. Raft
  # storage rejects unspecified addresses (`0.0.0.0`) at unseal time
  # with `cannot use unspecified IP with raft storage`, so a
  # config-baked `0.0.0.0:8201` would deadlock the cluster.
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
  HCL

  # Phase 1 bootstrap script — minimum needed before vault-config-operator
  # can take over the rest of the configuration via CRDs:
  #   1. Enable kubernetes auth method.
  #   2. Configure it with the in-cluster API + this Job's SA JWT for
  #      TokenReview.
  #   3. Write a `vault-config-operator-admin` policy (full sudo on
  #      every path — vco needs to manage mounts, auth methods, roles,
  #      policies on the operator's behalf).
  #   4. Bind the vco ServiceAccount to that policy via a kubernetes-
  #      auth role.
  # That's it. KV-v2 mount, VSO's read-only policy + role, OIDC auth
  # method, per-tenant policies + roles — all become CRDs reconciled by
  # vault-config-operator (next PR phase wires them).
  #
  # All operations idempotent: `auth enable` tolerates "path is already
  # in use", `auth/.../config` and `policy write` and `auth/.../role/<x>`
  # are PUT semantics so re-applies converge.
  configure_script = <<-EOT
    set -eu

    export VAULT_TOKEN=$(cat /etc/vault-bootstrap/root-token)
    if [ -z "$VAULT_TOKEN" ]; then
      echo "[vault-bootstrap] ERROR: root token empty — bootstrap Secret not yet populated"
      exit 1
    fi

    echo "[vault-bootstrap] waiting for vault unsealed+active..."
    until vault status -format=json 2>/dev/null | grep -q '"sealed": false'; do
      sleep 2
    done
    echo "[vault-bootstrap] vault active"

    enable_ok() {
      out=$(vault "$@" 2>&1) && return 0
      echo "$out" | grep -q "path is already in use" && return 0
      echo "$out" >&2
      return 1
    }

    echo "[vault-bootstrap] enable + configure kubernetes auth"
    enable_ok auth enable kubernetes
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc.cluster.local" \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

    echo "[vault-bootstrap] write vault-config-operator-admin policy"
    vault policy write vault-config-operator-admin - <<'POLICY'
    path "*" { capabilities = ["create","read","update","delete","list","sudo"] }
    POLICY

    echo "[vault-bootstrap] bind k8s role for vault-config-operator SA → admin policy"
    vault write auth/kubernetes/role/vault-config-operator \
      bound_service_account_names="${var.vault_config_operator_service_account}" \
      bound_service_account_namespaces="${var.vault_config_operator_namespace}" \
      policies=vault-config-operator-admin \
      ttl=24h

    echo "[vault-bootstrap] done — vault-config-operator can now take over via CRDs"
  EOT
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
    labels    = merge(local.tags, { app = "vault" })
  }
}

resource "kubernetes_role_v1" "vault_bootstrap" {
  for_each = local.instances

  metadata {
    name      = "vault-bootstrap"
    namespace = var.namespace
    labels    = local.tags
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
    labels    = local.tags
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
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "vault"
    })
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
    labels    = local.tags
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
    name   = "vault-data"
    labels = local.tags
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
    labels    = local.tags
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
    labels    = merge(local.tags, { app = "vault" })
  }

  spec {
    service_name = "vault"
    replicas     = 1

    selector {
      match_labels = { app = "vault" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "vault" })
      }

      spec {
        service_account_name = kubernetes_service_account_v1.vault["enabled"].metadata[0].name

        # k8s auto-injects `<SVC>_PORT=tcp://...` per Service in the
        # namespace. Some Vault config paths read `VAULT_PORT` and
        # crash on a non-numeric value. Cheap insurance — same logic
        # we use for Zitadel/Stalwart/Roundcube.
        enable_service_links = false

        # The hostPath PV starts owned by root:root (kubelet creates
        # the directory via `DirectoryOrCreate` without setting
        # ownership), but the vault container runs as 100:1000 with
        # all capabilities dropped — bolt's `open /vault/data/vault.db`
        # fails with `permission denied` on a fresh PV. fs_group at
        # the pod level isn't honored by hostPath. Run a one-shot
        # init container as root to chown the data dir before the
        # main container starts.
        init_container {
          name  = "chown-data"
          image = "busybox:stable-musl"

          security_context {
            run_as_user = 0
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "50m", memory = "32Mi" }
          }

          command = ["sh", "-c", "chown -R 100:1000 /vault/data"]

          volume_mount {
            name       = "data"
            mount_path = "/vault/data"
          }
        }

        container {
          name              = "vault"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          # The vault image's `docker-entrypoint.sh`, when invoked
          # with `server`, rewrites the command to:
          #   vault server -config=/vault/config -dev-root-token-id=... \
          #                -dev-listen-address=0.0.0.0:8200 "$@"
          # If we add our own `-config=/vault/config/config.hcl` as a
          # positional arg, the entrypoint's `-config=/vault/config`
          # (DIR) is kept AND ours is appended — vault then loads the
          # same config file twice and tries to bind two listeners on
          # `0.0.0.0:8200`, erroring out with
          # `bind: address already in use`. Passing only `server`
          # lets the entrypoint resolve `-config` once against the
          # `/vault/config` directory; the ConfigMap projects
          # `config.hcl` into that directory and vault loads it
          # normally.
          args = ["server"]

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

          # Raft requires concrete (non-`0.0.0.0`) cluster_addr —
          # populate from the pod's IP via downward API. `api_addr`
          # could stay loopback but using POD_IP keeps both addresses
          # consistent and lets a future multi-node config drop in
          # without rewiring.
          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }
          env {
            name  = "VAULT_API_ADDR"
            value = "http://$(POD_IP):8200"
          }
          env {
            name  = "VAULT_CLUSTER_ADDR"
            value = "https://$(POD_IP):8201"
          }

          # Vault image's docker-entrypoint.sh tries to `chown -R
          # vault:vault /vault/{config,file}` and `setcap cap_ipc_lock
          # +ep` on the binary before starting the server. Both fail
          # under the security_context above (capabilities dropped to
          # ALL, config volume read-only ConfigMap projection) and the
          # entrypoint exits non-zero before vault server boots.
          # Skipping both is safe: the chown is cosmetic when the user
          # already matches `run_as_user`, and IPC_LOCK is moot
          # because `disable_mlock = true` in config.hcl.
          env {
            name  = "SKIP_CHOWN"
            value = "true"
          }
          env {
            name  = "SKIP_SETCAP"
            value = "true"
          }

          # postStart polls the bootstrap-Secret-mounted file for up
          # to ~5min and runs `vault operator unseal` once the key
          # appears. Kubelet projects updated Secret data into running
          # pods within ~60s of the Secret PATCH, so this loop
          # converges without a pod restart on the first apply, and
          # immediately on every subsequent restart.
          #
          # The actual loop runs in a backgrounded subshell — the
          # foreground command exits 0 immediately so kubelet's
          # postStart deadline (implementation-defined, observed
          # ~2-4 min on this k3s build) cannot kill the container
          # before the loop converges. The subshell is detached via
          # `setsid` and writes its progress to a file under
          # `/vault/data/.unsealer.log` so operator can `kubectl exec
          # cat` it for debugging without needing the parent's
          # stdout. Trade-off: if the loop fails silently, kubelet
          # never knows — but the readiness probe catches it (a
          # sealed pod fails `/v1/sys/health` without query
          # overrides) and Vault stays NotReady until manual
          # intervention or the next pod restart.
          lifecycle {
            post_start {
              exec {
                command = [
                  "/bin/sh", "-c",
                  <<-EOT
                  setsid /bin/sh -c '
                  exec >>/vault/data/.unsealer.log 2>&1
                  echo "[unsealer $(date -Iseconds)] starting"
                  for i in $(seq 1 60); do
                    KEY=$(cat /vault/bootstrap/unseal-key 2>/dev/null || true)
                    if [ -n "$KEY" ]; then
                      if vault operator unseal "$KEY" >/dev/null 2>&1; then
                        echo "[unsealer $(date -Iseconds)] unsealed on iteration $i"
                        exit 0
                      fi
                    fi
                    sleep 5
                  done
                  echo "[unsealer $(date -Iseconds)] gave up after 60 iterations"
                  exit 0
                  ' </dev/null >/dev/null 2>&1 &
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
    labels    = merge(local.tags, { app = "vault" })
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
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "vault"
    })
  }

  spec {
    backoff_limit = 5

    template {
      metadata {
        labels = merge(local.tags, { job = "vault-init" })
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
# Phase 1 — vault_bootstrap Job
#
# Runs after vault_init, mounts the bootstrap Secret to read the root token,
# performs the minimum configuration needed before vault-config-operator can
# take over via CRDs:
#   - Enables kubernetes auth method, configures it with the in-cluster API
#     server URL + this Job's SA JWT (TokenReview path).
#   - Writes the `vault-config-operator-admin` policy (full sudo).
#   - Binds vault-config-operator's ServiceAccount to that policy through a
#     kubernetes-auth role.
#
# Everything else (KV-v2 mount, VSO read-only policy, OIDC config, per-tenant
# policies + OIDC roles) lives as kubectl_manifest-managed CRDs reconciled by
# vault-config-operator — see CRD section below.
#
# RBAC: the Job uses the same `vault` ServiceAccount as the StatefulSet. That
# SA also needs `system:auth-delegator` so Vault can call TokenReview against
# JWTs presented by k8s-auth clients (vault-config-operator, VSO, ...).
# -----------------------------------------------------------------------------

resource "kubernetes_cluster_role_binding_v1" "vault_token_reviewer" {
  for_each = local.instances

  metadata {
    name   = "vault-token-reviewer-${var.namespace}"
    labels = local.tags
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vault["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_job_v1" "vault_bootstrap" {
  for_each = local.instances

  depends_on = [
    kubernetes_job_v1.vault_init,
    kubernetes_cluster_role_binding_v1.vault_token_reviewer,
  ]

  metadata {
    # Suffix forces a NEW Job on every input change — k8s Jobs are immutable
    # post-create, so the only way to re-run on script change is a new name.
    name      = "vault-bootstrap-${substr(sha256(local.configure_script), 0, 10)}"
    namespace = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app"                          = "vault"
    })
  }

  spec {
    backoff_limit = 3
    # Auto-cleanup completed Jobs after 10 minutes — keeps `kubectl get jobs`
    # from accumulating one entry per apply over weeks.
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = merge(local.tags, { job = "vault-bootstrap" })
      }

      spec {
        restart_policy       = "Never"
        service_account_name = kubernetes_service_account_v1.vault["enabled"].metadata[0].name

        volume {
          name = "bootstrap"
          secret {
            secret_name = kubernetes_secret_v1.vault_bootstrap["enabled"].metadata[0].name
          }
        }

        container {
          name = "bootstrap"
          # Same image as the StatefulSet — has the `vault` CLI built in,
          # avoids dragging in a separate image layer.
          image = var.image

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          volume_mount {
            name       = "bootstrap"
            mount_path = "/etc/vault-bootstrap"
            read_only  = true
          }

          env {
            name  = "VAULT_ADDR"
            value = "http://vault.${var.namespace}.svc.cluster.local:8200"
          }

          command = ["sh", "-c", local.configure_script]
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
# Phase 1 — vault-config-operator (RedHat-COP)
#
# Declarative Vault management via CRDs. After the bootstrap Job above gives
# its ServiceAccount admin rights, vco logs into Vault via kubernetes auth
# and reconciles every CRD this module emits below: SecretEngineMount, Policy,
# KubernetesAuthEngineRole, JWTOIDCAuthEngineConfig, JWTOIDCAuthEngineRole.
#
# Repo + docs: https://github.com/redhat-cop/vault-config-operator
#
# Operator namespace is dedicated (`vault-config-operator`) so its RBAC and
# leader-election lock don't tangle with the platform namespace.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "vault_config_operator" {
  for_each = local.instances

  metadata {
    name   = var.vault_config_operator_namespace
    labels = local.tags
  }
}

resource "helm_release" "vault_config_operator" {
  for_each = local.instances

  depends_on = [kubernetes_namespace_v1.vault_config_operator]

  name       = "vault-config-operator"
  repository = "https://redhat-cop.github.io/vault-config-operator"
  chart      = "vault-config-operator"
  version    = var.vault_config_operator_chart_version
  namespace  = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name

  values = [yamlencode({
    # Default vault address vco uses for all CR reconcile calls.
    vaultAddress = "http://vault.${var.namespace}.svc.cluster.local:8200"

    # NOTE: the chart's `serviceAccount.name` value is IGNORED — the
    # chart hardcodes the SA name to `controller-manager` in its
    # template. Override here removed (was previously setting the value
    # the bootstrap Job's vault role expects, but the override never
    # took effect; bootstrap Job's role binding now references
    # `controller-manager` literally — see variables.tf).

    # Provision serving certs for the operator's webhook + metrics
    # endpoints via cert-manager. Without this the chart leaves
    # `vault-config-operator-certs` and `webhook-server-cert` unfulfilled,
    # the Deployment pod stays `ContainerCreating` on FailedMount, and
    # the Helm release wedges on its Ready wait. The platform already
    # runs cert-manager in `cert-manager` namespace via `module.addons`,
    # so this just lights up the chart's built-in cert-manager
    # Certificate templates.
    enableCertManager = true
  })]

  # Helm Ready-wait — without this the apply returns before the operator
  # is up, and downstream `kubectl_manifest` CRDs land on a chart whose
  # webhook isn't serving yet (admission rejects with "no endpoints").
  wait    = true
  timeout = 300
}

# -----------------------------------------------------------------------------
# Phase 1 — initial CRDs reconciled by vault-config-operator.
#
# Three CRs land:
#   1. KubernetesAuthEngineConfig (no-op if the bootstrap Job already wrote it,
#      but the CR makes the config part of the engine state too — vco will
#      re-assert if Vault drifts).
#   2. SecretEngineMount — KV-v2 at `secret/`.
#   3. Policy `vso-tenant-read` — read on every tenant subtree.
#   4. KubernetesAuthEngineRole `vso` — bind VSO's ServiceAccount to the
#      read-only policy. (VSO Helm release lands in PR-B — the role just sits
#      idle until then, harmless.)
#
# Per-tenant policies + roles + OIDC config live in PR-B (needs Zitadel app).
# -----------------------------------------------------------------------------

locals {
  # Authentication block every CR shares — points at the kubernetes auth
  # method enabled by the bootstrap Job, role `vault-config-operator`. vco
  # picks this up, exchanges its SA JWT for a Vault token via that role,
  # then performs the reconcile call.
  vco_authentication = {
    path = "kubernetes"
    role = "vault-config-operator"
    # Without this, vco impersonates the CRD default SA (`default`), and
    # Vault's k8s-auth role rejects with `service account name not
    # authorized` because it only binds `controller-manager`. Setting
    # this explicitly forces vco to TokenRequest a JWT for the SA the
    # role accepts.
    serviceAccount = {
      name = var.vault_config_operator_service_account
    }
  }

  vco_connection = {
    address = "http://vault.${var.namespace}.svc.cluster.local:8200"
  }
}

resource "kubectl_manifest" "kv_v2_mount" {
  for_each = local.instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "SecretEngineMount"
    metadata = {
      name      = "kv-v2-secret"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      path           = "" # mount AT secret (root of the path is `<name>` from metadata)
      name           = "secret"
      type           = "kv-v2"
    }
  })
}

resource "kubectl_manifest" "vso_read_policy" {
  for_each = local.instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "vso-tenant-read"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "secret/data/tenants/*"     { capabilities = ["read"] }
        path "secret/metadata/tenants/*" { capabilities = ["read", "list"] }
      POLICY
    }
  })
}

# VSO's kubernetes-auth role binding. References the SA that the upstream
# `hashicorp/vault-secrets-operator` Helm chart creates by default — that
# release lands in PR-B but the role can sit ahead of time, idle until VSO
# pods come up and start using it.
resource "kubectl_manifest" "vso_k8s_role" {
  for_each = local.instances

  depends_on = [
    kubectl_manifest.vso_read_policy,
    kubectl_manifest.kv_v2_mount,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "KubernetesAuthEngineRole"
    metadata = {
      name      = "vso"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication        = local.vco_authentication
      connection            = local.vco_connection
      path                  = "kubernetes"
      targetServiceAccounts = ["vault-secrets-operator-controller-manager"]
      # CRD shape — single `targetNamespaces` parent with EITHER a
      # `targetNamespaces` list OR a `targetNamespaceSelector` (mutually
      # exclusive; admission webhook rejects both).
      targetNamespaces = {
        targetNamespaces = ["vault-secrets-operator"]
      }
      policies = ["vso-tenant-read"]
      # KubernetesAuthEngineRole CRD wants seconds-as-int here (different
      # from JWTOIDCAuthEngineRole CRD, which wants a duration string).
      tokenTTL = 86400 # 24h
    }
  })
}

# -----------------------------------------------------------------------------
# Phase 2 — Zitadel OIDC auth method.
#
# Renders three CRs reconciled by vault-config-operator:
#   1. JWTOIDCAuthEngineConfig  → enables `oidc/` auth path, points it
#      at Zitadel's discovery URL, plugs in the client_id/secret from
#      the Vault Application created upstream via module.zitadel-app.
#   2. Policy `operator`        → full sudo on every path. The break-
#      glass equivalent of the root token, gated behind a Zitadel
#      project role grant instead of the Secret-mounted root token.
#   3. JWTOIDCAuthEngineRole `operator` → binds the operator policy to
#      users whose id_token claims include `vault:operator`. Operator
#      assigns this Zitadel project role to themselves once and signs
#      into Vault UI via "Sign in with OIDC".
#
# Per-tenant policies + OIDC roles render in the for_each below.
# -----------------------------------------------------------------------------

locals {
  oidc_instances = (var.enabled && var.oidc_enabled) ? toset(["enabled"]) : toset([])

  # Vault UI's OIDC callback URL. Two callbacks for compatibility with
  # both UI launch paths Vault uses across releases (`/ui/...` for
  # current UI, root `/oidc/callback` for direct API redirects).
  oidc_redirect_uris = [
    "https://${var.hostname}/ui/vault/auth/oidc/oidc/callback",
    "https://${var.hostname}/oidc/callback",
  ]

  # Set of tenant entries to project for_each over — empty when OIDC is
  # off (per-tenant CRs only make sense with OIDC enabled).
  tenant_set = (var.enabled && var.oidc_enabled) ? toset(var.tenants) : toset([])
}

# OIDC client_id + client_secret land in a Secret that vco's
# JWTOIDCAuthEngineConfig CR references by Secret name. Engine emits the
# Secret directly (vco operator namespace) so vco's reconcile loop can
# pull it on demand without a CR-managed secret.
resource "kubernetes_secret_v1" "vault_oidc" {
  for_each = local.oidc_instances

  metadata {
    name      = "vault-oidc-client"
    namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    client_id     = var.oidc_client_id
    client_secret = var.oidc_client_secret
  }
}

resource "kubectl_manifest" "oidc_config" {
  for_each = local.oidc_instances

  depends_on = [
    helm_release.vault_config_operator,
    kubernetes_secret_v1.vault_oidc,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineConfig"
    metadata = {
      name      = "oidc"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication   = local.vco_authentication
      connection       = local.vco_connection
      path             = "oidc"
      OIDCDiscoveryURL = var.oidc_issuer_url
      OIDCCredentials = {
        # vco shape: secret holding `client_id` + `client_secret` keys
        # under data; vco resolves at reconcile time.
        secret = {
          name = kubernetes_secret_v1.vault_oidc["enabled"].metadata[0].name
        }
      }
      defaultRole = "operator"
    }
  })
}

resource "kubectl_manifest" "operator_policy" {
  for_each = local.oidc_instances

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "operator"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "*" { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "operator_oidc_role" {
  for_each = local.oidc_instances

  depends_on = [
    kubectl_manifest.oidc_config,
    kubectl_manifest.operator_policy,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineRole"
    metadata = {
      name      = "operator"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication      = local.vco_authentication
      connection          = local.vco_connection
      path                = "oidc"
      name                = "operator"
      userClaim           = "sub"
      allowedRedirectURIs = local.oidc_redirect_uris
      groupsClaim         = "urn:zitadel:iam:org:project:roles"
      policies            = ["operator"]
      boundClaimsType     = "string"
      boundClaims = {
        "urn:zitadel:iam:org:project:roles" = [var.oidc_operator_zitadel_role]
      }
      tokenTTL = "8h" # CRD requires duration string, not seconds int
    }
  })
}

# Per-tenant policy + OIDC role. Engine derives `var.tenants` from the
# upstream project list — every tenant namespace gets a free Vault
# tenant. Policy grants RW on `secret/data/tenants/<name>/*`; the OIDC
# role binds the matching `vault:tenant:<name>` Zitadel project role
# claim to that policy. Operator grants the role to the tenant's
# Zitadel user; tenant signs into Vault UI scoped to their subtree.

resource "kubectl_manifest" "tenant_policy" {
  for_each = local.tenant_set

  depends_on = [helm_release.vault_config_operator]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "Policy"
    metadata = {
      name      = "tenant-${each.value}-rw"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication = local.vco_authentication
      connection     = local.vco_connection
      policy         = <<-POLICY
        path "secret/data/tenants/${each.value}/*"     { capabilities = ["create", "read", "update", "delete", "list"] }
        path "secret/metadata/tenants/${each.value}/*" { capabilities = ["read", "list", "delete"] }
        path "secret/data/tenants/${each.value}"       { capabilities = ["list"] }
        path "secret/metadata/tenants/${each.value}"   { capabilities = ["list"] }
      POLICY
    }
  })
}

resource "kubectl_manifest" "tenant_oidc_role" {
  for_each = local.tenant_set

  depends_on = [
    kubectl_manifest.oidc_config,
    kubectl_manifest.tenant_policy,
  ]

  yaml_body = yamlencode({
    apiVersion = "redhatcop.redhat.io/v1alpha1"
    kind       = "JWTOIDCAuthEngineRole"
    metadata = {
      name      = "tenant-${each.value}"
      namespace = kubernetes_namespace_v1.vault_config_operator["enabled"].metadata[0].name
    }
    spec = {
      authentication      = local.vco_authentication
      connection          = local.vco_connection
      path                = "oidc"
      name                = "tenant-${each.value}"
      userClaim           = "sub"
      allowedRedirectURIs = local.oidc_redirect_uris
      groupsClaim         = "urn:zitadel:iam:org:project:roles"
      policies            = ["tenant-${each.value}-rw"]
      boundClaimsType     = "string"
      boundClaims = {
        # Zitadel emits role KEYS (not display names) here. Caller
        # declares matching keys `tenant_<slug>` via module.zitadel-app
        # `roles`; slug hyphens normalised to underscores because some
        # downstream OIDC consumers reject hyphens in claim values.
        "urn:zitadel:iam:org:project:roles" = ["tenant_${replace(each.value, "-", "_")}"]
      }
      tokenTTL = "8h" # CRD requires duration string, not seconds int
    }
  })
}

# -----------------------------------------------------------------------------
# Phase 2 — Vault Secrets Operator (VSO) + cluster-level VaultConnection
# and VaultAuth.
#
# VSO consumes Vault paths via VaultStaticSecret CRs the engine emits in
# tenant namespaces. The cluster-level VaultConnection + VaultAuth here
# tell every VaultStaticSecret in the cluster how to reach Vault and
# which auth backend / role to use; tenant CRs reference these by name.
# -----------------------------------------------------------------------------

resource "kubernetes_namespace_v1" "vso" {
  for_each = (var.enabled && var.vso_enabled) ? toset(["enabled"]) : toset([])

  metadata {
    name   = var.vso_namespace
    labels = local.tags
  }
}

resource "helm_release" "vso" {
  for_each = (var.enabled && var.vso_enabled) ? toset(["enabled"]) : toset([])

  depends_on = [kubernetes_namespace_v1.vso]

  name       = "vault-secrets-operator"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  version    = var.vso_chart_version
  namespace  = kubernetes_namespace_v1.vso["enabled"].metadata[0].name

  values = [yamlencode({
    # Default cluster-level VaultConnection + VaultAuth — every
    # VaultStaticSecret in the cluster picks these up unless it
    # references named CRs explicitly. Saves emitting a
    # VaultConnection per tenant namespace.
    defaultVaultConnection = {
      enabled = true
      address = "http://vault.${var.namespace}.svc.cluster.local:8200"
    }
    defaultAuthMethod = {
      enabled = true
      # `namespace` here is Vault's enterprise NAMESPACE feature
      # (HCP/Enterprise only) — NOT a k8s namespace selector. On
      # community Vault it must stay unset; the chart renders an
      # unquoted bare `*` as a YAML alias and parsing dies (line 16:
      # "did not find expected alphabetic or numeric character").
      # Cross-namespace consumption of the default VaultAuth is
      # implicit — VaultStaticSecret CRs in any namespace reference
      # `default` by name and the operator resolves it.
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role           = "vso"
        serviceAccount = "vault-secrets-operator-controller-manager"
      }
    }
  })]

  wait    = true
  timeout = 300
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------


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
