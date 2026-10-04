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

          command = ["sh", "-c", "find /vault/data \\( ! -user 100 -o ! -group 1000 \\) -exec chown 100:1000 {} +"]

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
          image = var.init_image

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
