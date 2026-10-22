# Samba file server (ServerContainers image) — LAN shares over SMB.
#
# Everything is configured by environment variables the image's
# entrypoint turns into smb.conf: `ACCOUNT_<user>` (password, from
# Vault via VSO), `UID_<user>` (file owner uid), `SAMBA_GLOBAL_STANZA`
# (`;`-separated [global] lines) and one `SAMBA_VOLUME_CONFIG_<share>`
# per share.
#
# Exposure is a MetalLB L2 LoadBalancer with `externalTrafficPolicy:
# Local` — Samba then sees the real client IP and `hosts allow` works
# on LAN addresses. `allocateLoadBalancerNodePorts=false` keeps SMB
# off every node's NodePort range.
#
# `seed` copies an existing directory tree in before the server
# starts: a hostPath PV/PVC pair (the PV indirection is what lets a
# PSA-baseline pod read hostPath data — #268, same trick as
# modules/component) and an rsync init container that mirrors it onto
# the shares volume on every start while set. First run is full copy,
# later runs are deltas; clear `seed` before going read-write.

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
  }
}

locals {
  # Seed claim name, shared by the claim and the Deployment's volume (which
  # names it rather than referencing the resource; see there).
  seed_claim_name = "samba-seed"
  instances       = var.enabled ? toset(["enabled"]) : toset([])
  seed            = var.enabled && var.seed != null

  tags = module.label.tags

  # Accounts sorted by name (stable across plans) — used wherever "all
  # users" is the default.
  user_names = sort(keys(var.users))

  # Owner of each share's directory = uid of its first valid user,
  # falling back to the first declared account. `try` lets a bad
  # `valid_users` entry reach the precondition below instead of
  # failing the plan with an opaque index error.
  share_owner_uid = {
    for share in var.shares :
    share.name => try(
      var.users[length(share.valid_users) > 0 ? share.valid_users[0] : local.user_names[0]].uid,
      0
    )
  }

  global_stanza = join(";", [
    "server min protocol = SMB3",
    "restrict anonymous = 2",
    "hosts allow = ${join(" ", concat(["127.0.0.1"], var.allowed_networks))}",
    "hosts deny = ALL",
    "load printers = no",
    "printcap name = /dev/null",
    "disable spoolss = yes",
  ])

  # ServerContainers env contract.
  samba_env = merge(
    {
      AVAHI_DISABLE       = "1"
      WSDD2_DISABLE       = "1"
      NETBIOS_DISABLE     = "1"
      SAMBA_GLOBAL_STANZA = local.global_stanza
    },
    { for name, u in var.users : "UID_${name}" => tostring(u.uid) },
    {
      for share in var.shares :
      "SAMBA_VOLUME_CONFIG_${share.name}" => join(";", [
        "[${share.name}]",
        "path = /shares/${share.name}",
        "browseable = yes",
        "read only = ${share.read_only ? "yes" : "no"}",
        "valid users = ${join(" ", length(share.valid_users) > 0 ? share.valid_users : local.user_names)}",
      ])
    }
  )
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "samba"
  tags = {
    "app.kubernetes.io/component" = "samba"
  }
}

# ── Configuration checks ───────────────────────────────────────────────────

resource "terraform_data" "checks" {
  for_each = local.instances

  lifecycle {
    precondition {
      condition     = var.storage_class != ""
      error_message = "var.storage_class is required — use a replicated class so the pod can restart on another storage node."
    }
    precondition {
      condition     = var.load_balancer_ip != ""
      error_message = "var.load_balancer_ip is required — the fixed LAN address clients mount `smb://<address>/<share>` on."
    }
    precondition {
      condition     = var.address_pool != ""
      error_message = "var.address_pool is required — the MetalLB pool `load_balancer_ip` is allocated from."
    }
    precondition {
      condition     = length(var.node_hostnames) > 0
      error_message = "var.node_hostnames is required — the nodes the file server may run on (with a replicated volume: the nodes holding the copies)."
    }
    precondition {
      condition     = length(var.users) > 0
      error_message = "var.users is required — declare at least one account (passwords come from Vault at `vault_path`)."
    }
    precondition {
      condition     = length(var.shares) > 0
      error_message = "var.shares is required — a file server exporting nothing is a misconfiguration."
    }
    precondition {
      condition     = length(var.allowed_networks) > 0
      error_message = "var.allowed_networks is required — `hosts deny = ALL` would lock every client out otherwise."
    }
    precondition {
      condition = alltrue(flatten([
        for share in var.shares :
        [for u in share.valid_users : contains(keys(var.users), u)]
      ]))
      error_message = "Every `valid_users` entry must be an account declared in var.users; unknown: ${join(", ", distinct(flatten([for s in var.shares : [for u in s.valid_users : u if !contains(keys(var.users), u)]])))}."
    }
    precondition {
      # A conditional, not `||`: both sides of `||` may be evaluated.
      condition     = var.seed == null ? true : contains(var.node_hostnames, var.seed.node)
      error_message = "var.seed.node must be in var.node_hostnames — while seeding the pod is pinned to that node and cannot run on a node it is not allowed on."
    }
  }
}

# ── Namespace (PSA baseline) ───────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
    })
  }
}

# ── Account passwords from Vault (VSO) ──────────────────────────────────────

# VSO impersonates the SA in the namespace where the VaultStaticSecret
# lives — it must exist here before the CR reconciles (same pattern as
# modules/github-runners `vso_proxy`).
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = local.instances

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
    })
  }
}

# Own VaultAuth when a narrow role is given, instead of VSO's default.
resource "kubectl_manifest" "vault_auth" {
  for_each = var.enabled && var.vault_auth_role != "" ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "vault-samba"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels = merge(local.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role                   = var.vault_auth_role
        serviceAccount         = kubernetes_service_account_v1.vso_proxy["enabled"].metadata[0].name
        tokenExpirationSeconds = 600
      }
    }
  })
}

# One key per account at `var.vault_path`; rendered into
# `ACCOUNT_<user>` env keys the image expects. `excludes: [".*"]` +
# `excludeRaw` drop the passthrough keys/`_raw` blob so only the
# templated entries land in the Secret. A password change restarts the
# pod via rolloutRestartTargets.
resource "kubectl_manifest" "accounts_vault" {
  for_each = local.instances

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_service_account_v1.vso_proxy,
    kubectl_manifest.vault_auth,
  ]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "samba-accounts"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels = merge(local.tags, {
        "app.kubernetes.io/managed-by" = "terraform"
      })
    }
    spec = {
      vaultAuthRef = var.vault_auth_role != "" ? "vault-samba" : ""
      mount        = "secret"
      type         = "kv-v2"
      path         = var.vault_path
      destination = {
        name   = "samba-accounts"
        create = true
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates = {
            for name in keys(var.users) :
            "ACCOUNT_${name}" => { text = "{{- get .Secrets \"${name}\" -}}" }
          }
        }
      }
      rolloutRestartTargets = [{
        kind = "Deployment"
        name = "samba"
      }]
      refreshAfter = "30s"
    }
  })
}

# ── Shares volume ──────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "data" {
  for_each = local.instances

  metadata {
    name      = "samba-data"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class

    resources {
      requests = {
        storage = var.size
      }
    }
  }

  # WaitForFirstConsumer classes bind when the pod is scheduled.
  wait_until_bound = false
}

# ── Seed (optional): old data lives on a hostPath on one node ───────────────
#
# A static PV + a PVC bound to it by `volume_name` is how a
# baseline-PSS pod reads hostPath data: hostPath volumes are forbidden
# in pod spec, hostPath PVs are not (#268).

resource "kubernetes_persistent_volume_v1" "seed" {
  for_each = local.seed ? toset(["enabled"]) : toset([])

  metadata {
    name   = "${var.namespace}-samba-seed"
    labels = local.tags
  }

  spec {
    capacity = {
      storage = var.size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    # A class name no provisioner owns, set on both the PV and the claim:
    # an empty one may be dropped by the provider, and the cluster's
    # default class would then be stamped on the claim, which never binds
    # (same as modules/component's hostPath PVs).
    storage_class_name = "samba-seed"

    persistent_volume_source {
      host_path {
        path = var.seed.host_path
        type = "Directory"
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [var.seed.node]
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "seed" {
  for_each = local.seed ? toset(["enabled"]) : toset([])

  metadata {
    name      = local.seed_claim_name
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "samba-seed"
    volume_name        = kubernetes_persistent_volume_v1.seed["enabled"].metadata[0].name

    resources {
      requests = {
        storage = var.size
      }
    }
  }
}

# ── Deployment ─────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  for_each = local.instances

  depends_on = [
    terraform_data.checks,
    kubectl_manifest.accounts_vault,
    kubernetes_persistent_volume_claim_v1.data,
    kubernetes_persistent_volume_claim_v1.seed,
  ]

  # The first seed rsync runs for hours — waiting for rollout would
  # just hold the apply open for it.
  wait_for_rollout = false

  metadata {
    name      = "samba"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels = merge(local.tags, {
      "app" = "samba"
    })
  }

  spec {
    replicas = 1

    # RWO volume: a second replica mid-rollout could not mount it anyway.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app" = "samba"
      }
    }

    template {
      metadata {
        labels = merge(local.tags, {
          "app" = "samba"
        })
      }
      spec {
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "In"
                  values   = var.node_hostnames
                }
              }
            }
          }
        }

        # Kubernetes defaults these tolerations to 300s; shorter means a
        # crashed node's SMB address is back on a healthy node faster.
        toleration {
          key                = "node.kubernetes.io/not-ready"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = var.failover_seconds
        }
        toleration {
          key                = "node.kubernetes.io/unreachable"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = var.failover_seconds
        }

        # Order matters: the copy runs first, the mkdir/chown pass after
        # it (it only fixes directories rsync did not already create).
        dynamic "init_container" {
          for_each = local.seed ? [1] : []
          content {
            name  = "seed"
            image = var.seed_image
            # --delete mirrors the source: an empty or missing source (the old
            # disk gone or rebuilt) would wipe the volume, so refuse unless it
            # holds at least one file.
            command = ["sh", "-c", <<-EOT
              if [ -z "$(find /old -mindepth 1 -path /old/lost+found -prune -o -type f -print -quit 2>/dev/null)" ]; then
                echo "seed: /old has no files; refusing to mirror an empty source over the volume" >&2
                exit 1
              fi
              exec rsync -aHAX --numeric-ids --delete --exclude=/lost+found /old/ /shares/
            EOT
            ]

            # mirroring module.volume_seed's sizing — the copy goes
            # through the page cache, which counts against the
            # container's memory limit.
            resources {
              requests = { cpu = "10m", memory = "64Mi" }
              limits   = { cpu = "1", memory = "1Gi" }
            }

            security_context {
              run_as_user = 0
            }

            volume_mount {
              name       = "old"
              mount_path = "/old"
              read_only  = true
            }
            volume_mount {
              name       = "shares"
              mount_path = "/shares"
            }
          }
        }

        init_container {
          name  = "shares"
          image = var.image
          command = [
            "sh", "-c",
            <<-EOT
              set -eu
              %{for share in var.shares~}
              [ -d '/shares/${share.name}' ] || { mkdir '/shares/${share.name}' && chown ${local.share_owner_uid[share.name]}:${local.share_owner_uid[share.name]} '/shares/${share.name}'; }
              %{endfor~}
            EOT
          ]

          security_context {
            run_as_user = 0
          }

          volume_mount {
            name       = "shares"
            mount_path = "/shares"
          }
        }

        container {
          name              = "samba"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          env_from {
            secret_ref {
              name = "samba-accounts"
            }
          }

          dynamic "env" {
            for_each = local.samba_env
            content {
              name  = env.key
              value = env.value
            }
          }

          port {
            name           = "smb"
            container_port = 445
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          readiness_probe {
            tcp_socket {
              port = 445
            }
          }
          liveness_probe {
            tcp_socket {
              port = 445
            }
            # The entrypoint creates the accounts and smb.conf first.
            initial_delay_seconds = 15
          }

          volume_mount {
            name       = "shares"
            mount_path = "/shares"
          }
        }

        volume {
          name = "shares"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.data["enabled"].metadata[0].name
          }
        }

        dynamic "volume" {
          for_each = local.seed ? [1] : []
          content {
            name = "old"
            persistent_volume_claim {
              # By name, not by reference: with a dependency, clearing `seed`
              # made Terraform delete the claim (held by the running pod,
              # pvc-protection) before updating this Deployment, and the apply
              # hung. Without one both run at once: the pod is replaced, the
              # claim is released and its delete completes. On creation the
              # pod waits for the claim like for any unbound one. Replacing
              # the seed (new source or size) keeps this name, so the running
              # pod would still hold the old claim: clear `seed`, apply, then
              # set the new one.
              claim_name = local.seed_claim_name
              read_only  = true
            }
          }
        }
      }
    }
  }
}

# ── Service (MetalLB L2) ───────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "samba"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
    annotations = {
      # Canonical MetalLB v0.15+ annotations — the deprecated
      # `metallb.universe.tf/*` names are ignored.
      "metallb.io/address-pool"    = var.address_pool
      "metallb.io/loadBalancerIPs" = var.load_balancer_ip
    }
  }

  spec {
    type = "LoadBalancer"

    # `Local` preserves the real client source IP — `hosts allow` then
    # sees LAN addresses, not the SNAT'd node IP.
    external_traffic_policy = "Local"
    # No NodePorts: otherwise port 445 would open on every node,
    # including public-facing ones.
    allocate_load_balancer_node_ports = false

    selector = {
      "app" = "samba"
    }

    port {
      name        = "smb"
      port        = 445
      target_port = "smb"
      protocol    = "TCP"
    }
  }

  # MetalLB stamps `metallb.io/ip-allocated-from-pool` at runtime; ignore
  # just that one bookkeeping key (same as traefik_public.tf).
  lifecycle {
    ignore_changes = [
      metadata[0].annotations["metallb.io/ip-allocated-from-pool"],
    ]
  }
}
