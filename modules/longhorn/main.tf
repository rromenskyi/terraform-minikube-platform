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

# ── Inputs ─────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Whether to deploy Longhorn. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Longhorn lives in. Convention is `longhorn-system`; the chart hardcodes it for several internal references, so override only if a fleet-wide policy requires a different one."
  type        = string
  default     = "longhorn-system"
}

variable "version_pin" {
  description = "Helm chart version for longhorn/longhorn. Pinned so an upstream re-tag doesn't change behavior across applies."
  type        = string
  default     = "1.11.1"
}

variable "default_replica_count" {
  description = "Number of replicas Longhorn maintains for every new volume. 3 = one per node on a 3-node cluster (default). 1 keeps the volume single-node — useful for single-node dev clusters where the durability guarantee doesn't apply anyway."
  type        = number
  default     = 3
}

variable "default_data_path" {
  description = "Host directory each Longhorn instance-manager pod writes replica data to. Should NOT be the same path the platform's hostPath PVs use — keep blast radius separate."
  type        = string
  default     = "/var/lib/longhorn/"
}

variable "tolerations" {
  description = "Tolerations propagated to every Longhorn pod (manager DaemonSet, CSI components, UI, instance-managers). Empty = Longhorn pods land only on un-tainted nodes; on a tainted-edge or tainted-control-plane setup the storage layer must tolerate the same taints workloads do, otherwise replicas can't bind to those nodes and `replicaCount` can't be satisfied. Standard k8s toleration shape — passed both to the chart's `longhornManager` / `longhornUI` / `longhornDriver` values AND rendered into the Longhorn-format `taintToleration` setting for dynamic instance-managers."
  type = list(object({
    key                = optional(string)
    operator           = optional(string, "Exists")
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "backup_b2_bucket" {
  description = "B2 bucket for Longhorn native backups. May share the bucket with the restic backup pipeline; Longhorn's data lands under a separate `longhorn-volumes/` prefix automatically. Empty disables backup-target configuration; volumes still work, just can't be backed up via Longhorn's `BackupTarget` API."
  type        = string
  default     = ""
}

variable "backup_b2_endpoint" {
  description = "S3-compatible endpoint URL for the B2 region (`https://s3.<region>.backblazeb2.com`). Required when `backup_b2_bucket` is set."
  type        = string
  default     = ""
}

variable "backup_b2_region" {
  description = "Token Longhorn embeds in the `s3://<bucket>@<region>/` URL. B2 doesn't enforce AWS regional routing; the value just has to be non-empty. Uses the bucket region name from the endpoint by default."
  type        = string
  default     = "us-east-005"
}

variable "backup_b2_access_key_id" {
  description = "B2 application key id with read/write to `backup_b2_bucket`. Sourced from the operator's gitignored `.env`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "backup_b2_secret_access_key" {
  description = "B2 application key secret matching `backup_b2_access_key_id`."
  type        = string
  default     = ""
  sensitive   = true
}

variable "recurring_backup_cron" {
  description = "Cron schedule (UTC) for the per-volume daily backup RecurringJob applied to the `longhorn` StorageClass. Default 04:30 UTC — late enough that the platform restic backups (03:00–04:00 UTC) are done so the two pipelines don't compete for B2 bandwidth."
  type        = string
  default     = "30 4 * * *"
}

variable "recurring_backup_retain" {
  description = "Number of daily backups Longhorn keeps per volume before pruning. Pair with `recurring_backup_cron` — together they define the per-volume retention window."
  type        = number
  default     = 7
}

# ── Locals ────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Only check the non-sensitive vars in this derivation —
  # `for_each` rejects values derived from sensitive inputs.
  # The check block at the root level confirms the matching
  # creds are also present when the bucket+endpoint are set.
  backup_configured = (
    var.enabled &&
    var.backup_b2_bucket != "" &&
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
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "longhorn-backup"
    }
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

# ── Outputs ───────────────────────────────────────────────────────────────

output "namespace" {
  value       = var.enabled ? var.namespace : null
  description = "Longhorn namespace, null when disabled."
}

output "storage_class" {
  value       = var.enabled ? "longhorn" : null
  description = "StorageClass name to set on PVCs that should land on Longhorn-managed volumes. The chart creates the class itself; this output is just a stable reference for callers."
}

output "backup_target" {
  value       = local.backup_configured ? local.backup_target_url : null
  description = "Longhorn S3 backup target URL, or null when backup is unconfigured."
}
