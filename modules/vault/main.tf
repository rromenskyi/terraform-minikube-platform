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
    # token_reviewer_jwt comes from a long-lived SA token Secret
    # (/etc/vault-token-reviewer/token), NOT the Job's projected
    # token (1h TTL — Vault rejects post-expiry, leaving the field
    # effectively unset). With a non-bound long-lived JWT here,
    # Vault uses its OWN identity (vault SA, has system:auth-delegator)
    # to call TokenReview against incoming login JWTs, decoupling
    # consumer auth from each consumer needing TokenReview perms.
    vault write auth/kubernetes/config \
      kubernetes_host="https://kubernetes.default.svc.cluster.local" \
      kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
      token_reviewer_jwt=@/etc/vault-token-reviewer/token

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

# Long-lived SA token Secret for the vault SA. K8s 1.24+ no longer
# auto-creates SA token Secrets — only short-lived projected tokens
# (1h default). The bootstrap Job needs a long-lived JWT to write to
# Vault's `auth/kubernetes/config.token_reviewer_jwt`; with that set,
# Vault uses ITS OWN identity (vault SA, has system:auth-delegator)
# to call TokenReview against incoming login JWTs, decoupling the
# auth flow from each consuming SA needing TokenReview perms.
# Without this, Vault falls back to using the incoming JWT for
# TokenReview, which may or may not have auth-delegator depending
# on the consumer.
resource "kubernetes_secret_v1" "vault_token_reviewer" {
  for_each = local.instances

  metadata {
    name      = "vault-token-reviewer"
    namespace = var.namespace
    labels    = local.tags
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.vault["enabled"].metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"

  # k8s populates `data.token` (and ca.crt + namespace) automatically
  # once the SA exists. Fight against TF marking data drift on every
  # plan — we never write data here, only read.
  lifecycle {
    ignore_changes = [data]
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
# Storage for /vault/data (raft state).
#
# Two shapes, picked by `var.storage_class`:
#   "" / "standard"  → static hostPath PV declared below + PVC bound to it.
#                       Node-local; survives pod restart, NOT node loss.
#   <other>          → no PV declared (dynamic provisioning); PVC requests
#                       the named StorageClass. Used for "longhorn" — survives
#                       node loss + reschedules cleanly.
# -----------------------------------------------------------------------------

locals {
  use_static_hostpath = var.storage_class == "" || var.storage_class == "standard"
  effective_sc        = local.use_static_hostpath ? "standard" : var.storage_class
}

resource "kubernetes_persistent_volume_v1" "vault" {
  for_each = local.use_static_hostpath ? local.instances : toset([])

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
    storage_class_name = local.effective_sc
    # In static-hostPath mode, bind explicitly to the engine-declared PV
    # (`claim_ref` on the PV side + `volume_name` here). In dynamic mode
    # (longhorn etc), let the provisioner pick.
    volume_name = local.use_static_hostpath ? kubernetes_persistent_volume_v1.vault["enabled"].metadata[0].name : null

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }
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
