# Longhorn — distributed block storage.
#
# Replaces the per-node hostPath PV pattern for any tenant
# component that opts in via `storage_class: longhorn`. Volumes
# are replicated across the cluster (default 3 replicas, one per
# node), so the consuming pod can schedule on any node and
# Longhorn attaches the right replica locally.
#
# Backups land on the same B2 bucket the restic pipeline uses,
# under a dedicated `longhorn-volumes/` prefix — Longhorn's
# native backup format isn't restic-compatible, so the two
# pipelines stay side-by-side rather than one feeding the other.
# Recurring jobs (daily backup, retention) are configured by
# annotation on the StorageClass and apply to every volume of
# that class.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
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


# ── Locals ────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Shorthand for the propagated null-label tag set.
  tags = module.label.tags

  # Only check the non-sensitive vars in this derivation —
  # `for_each` rejects values derived from sensitive inputs.
  # The check block at the root level confirms the matching
  # creds are also present when the bucket+endpoint are set.
  backup_configured = (
    var.enabled &&
    var.backup_b2_bucket != "" &&
    var.backup_b2_region != "" &&
    var.backup_b2_endpoint != ""
  )

  # `s3://bucket@region/prefix/` — Longhorn's expected URL shape
  # for S3-compatible backup targets. The trailing slash matters;
  # without it Longhorn rejects the URL at startup.
  backup_target_url = local.backup_configured ? "s3://${var.backup_b2_bucket}@${var.backup_b2_region}/longhorn-volumes/" : ""

  # Render `var.tolerations` into Longhorn's
  # `<key>=<value>:<effect>;<key>:<effect>` setting string. Used
  # for dynamic instance-manager pods (chart-level pods get the
  # raw list via `longhornManager.tolerations` etc. below).
  taint_toleration_setting = join(";", [
    for t in var.tolerations :
    "${t.key}${t.value == null ? "" : "=${t.value}"}:${t.effect}"
  ])

  # K8s tolerations shape — passed verbatim to chart-level pods.
  chart_tolerations = [
    for t in var.tolerations : {
      key               = t.key
      operator          = t.operator
      value             = t.value
      effect            = t.effect
      tolerationSeconds = try(tonumber(t.toleration_seconds), null)
    }
  ]

  # Helm values rendered conditionally on whether B2 backup
  # config is complete. Without it, the chart still installs and
  # provisions volumes — operators just can't back them up via
  # Longhorn's API until they fill in the `backup_b2_*` inputs
  # and re-apply.
  values = yamlencode({
    persistence = {
      defaultClass             = false
      defaultClassReplicaCount = var.default_replica_count
      reclaimPolicy            = "Retain"
    }
    longhornManager = {
      tolerations = local.chart_tolerations
    }
    longhornDriver = {
      tolerations = local.chart_tolerations
    }
    longhornUI = {
      tolerations = local.chart_tolerations
    }
    defaultSettings = merge(
      {
        defaultDataPath     = var.default_data_path
        defaultReplicaCount = var.default_replica_count
        # Strict per-node anti-affinity. With `false`, Longhorn
        # refuses to create a replica if no node has free space —
        # better than `true` (best-effort) because the latter can
        # silently pile multiple replicas on one node during
        # transient pressure, breaking the durability guarantee.
        # On a 3-node cluster with replicaCount = 3, this gives
        # exactly one replica per node, every time. Trade-off:
        # if a node goes down for an extended window, Longhorn
        # waits for it to return rather than rebalancing onto a
        # surviving node — but for our blast-radius shape, that's
        # the right call.
        replicaSoftAntiAffinity = false
        # Allow the chart's preflight DaemonSet to surface kernel
        # / package issues (`open-iscsi`, `nfs-common`) up front
        # rather than during the first volume mount.
        guaranteedInstanceManagerCPU = 12
        # Tolerations for dynamic Longhorn-managed pods (instance-
        # managers, share-managers, system-managed jobs). Same
        # taints as chart-level components — keep them in sync.
        taintToleration = local.taint_toleration_setting
      },
      local.backup_configured ? {
        backupTarget                 = local.backup_target_url
        backupTargetCredentialSecret = "longhorn-backup-credentials"
      } : {}
    )
  })
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "longhorn"
  tags = {
    "app.kubernetes.io/component" = "longhorn"
  }
}

# ── Resources ─────────────────────────────────────────────────────────────

# Backup credentials Secret. Format mandated by Longhorn:
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_ENDPOINTS,
# the third one carrying the S3-compatible endpoint URL so
# Longhorn doesn't try to talk to AWS regional routing.
resource "kubernetes_secret_v1" "backup_credentials" {
  for_each = local.backup_configured ? toset(["enabled"]) : toset([])

  depends_on = [helm_release.longhorn]

  metadata {
    name      = "longhorn-backup-credentials"
    namespace = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "longhorn-backup"
    })
  }

  data = {
    AWS_ACCESS_KEY_ID     = var.backup_b2_access_key_id
    AWS_SECRET_ACCESS_KEY = var.backup_b2_secret_access_key
    AWS_ENDPOINTS         = var.backup_b2_endpoint
  }
}

resource "helm_release" "longhorn" {
  for_each = local.instances

  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = var.version_pin
  namespace        = var.namespace
  create_namespace = true

  # Bring-up takes longer than the standard chart — instance
  # manager + engine images get pulled on every node, plus the
  # webhook waits for cert-manager-style cert provisioning.
  timeout = 1200

  values = [local.values]
}

# ── Sibling StorageClasses per operator-defined topology pool ─────────────
#
# Default `longhorn` StorageClass spreads replicas across all
# Longhorn-registered nodes per the chart's anti-affinity rules.
# In a multi-DC cluster (home + VPS through WireGuard mesh) this
# puts replicas on VPS reachable only over the internet, adding
# 100-200ms per synchronous write — acceptable for object stores
# but ruinous for latency-sensitive Redis/Valkey-class workloads.
#
# `var.tag_pools` lets the operator declare topology pools; each
# entry emits a sibling StorageClass `longhorn-<key>` whose volumes
# are constrained to nodes carrying the matching Longhorn node tag.
# Engine stays generic: the keys / tag names / replica counts are
# all operator-decided. Tagging is operator-side one-time:
#
#   kubectl -n longhorn-system patch node.longhorn.io <node> \
#     --type=merge -p '{"spec":{"tags":["<key>"]}}'
#
# PVCs opt in by setting `storageClassName: longhorn-<key>`.
# Without the tag applied to at least `replicas` nodes, PVCs of
# the corresponding class stay Pending until tags are placed.

resource "kubernetes_storage_class_v1" "tag_pool" {
  for_each = var.enabled ? var.tag_pools : {}

  depends_on = [helm_release.longhorn]

  metadata {
    name   = "longhorn-${each.key}"
    labels = local.tags
  }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = each.value.reclaim_policy
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true
  parameters = {
    numberOfReplicas    = tostring(each.value.replicas)
    nodeSelector        = each.key
    dataLocality        = each.value.data_locality
    fsType              = each.value.fs_type
    staleReplicaTimeout = "30"
  }
}

# ── Recurring backup job ───────────────────────────────────────────────────
#
# Volumes annotated with `recurring-job-selector.longhorn.io/<group>`
# pick up every RecurringJob that targets that group. Default
# group `default` matches everything so any volume created by
# the platform inherits the daily backup. Operators that want to
# opt out per-volume can override via PVC annotations.

resource "kubectl_manifest" "recurring_backup" {
  for_each = local.backup_configured ? toset(["enabled"]) : toset([])

  depends_on = [helm_release.longhorn, kubernetes_secret_v1.backup_credentials]

  yaml_body = yamlencode({
    apiVersion = "longhorn.io/v1beta2"
    kind       = "RecurringJob"
    metadata = {
      name      = "platform-default-backup"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      name        = "platform-default-backup"
      task        = "backup"
      cron        = var.recurring_backup_cron
      retain      = var.recurring_backup_retain
      concurrency = 2
      groups      = ["default"]
      labels = {
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
  })
}

