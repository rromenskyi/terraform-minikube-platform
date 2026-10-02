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

# vco's controller-manager SA also needs system:auth-delegator. Vault's
# k8s auth method config has `token_reviewer_jwt` empty (we never wrote
# a long-lived SA token Secret for the bootstrap Job to consume), so
# Vault falls back to using the INCOMING login JWT itself when calling
# TokenReview against the API server. That JWT is vco's own SA token —
# it must carry the right to call TokenReview, otherwise login 403s
# with "permission denied" even though the bound SA / namespace match.
# Adding system:auth-delegator to controller-manager closes that loop.
resource "kubernetes_cluster_role_binding_v1" "vco_token_reviewer" {
  for_each = local.instances

  depends_on = [kubernetes_namespace_v1.vault_config_operator]

  metadata {
    name   = "vault-config-operator-token-reviewer"
    labels = local.tags
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.vault_config_operator_service_account
    namespace = var.vault_config_operator_namespace
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
    # No ttl_seconds_after_finished: a TTL self-deletes the completed Job, so
    # every apply re-plans a `create` and RE-RUNS the bootstrap (churn — and it
    # re-emits sensitive config to the Job log each time). The Job name is
    # hash-suffixed on the configure script, so an unchanged script keeps the
    # same name and the lingering completed Job means TF sees it and does not
    # re-create. Old hash-named Jobs only accumulate when the script actually
    # changes (rare); clean those up by hand if they ever pile up.

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

        volume {
          name = "tokenreviewer"
          secret {
            secret_name = kubernetes_secret_v1.vault_token_reviewer["enabled"].metadata[0].name
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

          volume_mount {
            name       = "tokenreviewer"
            mount_path = "/etc/vault-token-reviewer"
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
