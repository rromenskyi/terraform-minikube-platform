# MinIO — S3-compatible object store for the platform.
#
# Single-replica Deployment + PVC. Use case: per-tenant archive
# buckets where the consuming workload needs an S3 endpoint and the
# operator doesn't want a cloud dependency. Engine emits one
# bucket-credentials Secret per `buckets:` entry in the operator
# config; the consumer chart `envFrom`s it (standard
# `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` / `S3_ENDPOINT` /
# `S3_REGION` / `S3_BUCKET` / `S3_PATH_STYLE` keys).
#
# MinIO's bundled IAM is shared per-instance — the engine creates
# one root credential for itself and per-bucket service-account
# keys for tenants. Per-bucket auto-creation runs as a Kubernetes
# Job (mc cli image) that mc-aliases the root creds + `mc mb` +
# `mc admin user svcacct add` for each bucket; idempotent across
# applies.
#
# Storage class operator-supplied via `var.storage_class`. Empty =
# default (hostPath / local-path on k3s); set to a Longhorn pool SC
# for cross-node replication.

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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# ── Inputs ─────────────────────────────────────────────────────────────────

variable "enabled" {
  description = "Whether to deploy MinIO. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace MinIO lives in. Convention is `platform`; the chart's bucket Secrets land in the consumer namespaces (see `var.buckets`), not here."
  type        = string
  default     = "platform"
}

variable "image" {
  description = "MinIO server container image. Pinned by tag — auto-update is opt-in via operator bumping the tag."
  type        = string
  default     = "minio/minio:RELEASE.2025-09-07T16-13-09Z"
}

variable "mc_image" {
  description = "MinIO Client image used by the bucket-provisioning Job. `mc admin user svcacct` shape is stable across recent releases. Tag is verified-pullable; bump as upstream cuts new releases."
  type        = string
  default     = "minio/mc:RELEASE.2025-08-13T08-35-41Z"
}

variable "storage_class" {
  description = "StorageClass for the MinIO PVC. Empty = cluster default (typically `local-path` on k3s, single-node hostPath). Set to a Longhorn pool SC name (e.g. `longhorn-stateful`) for cross-node replication so node-loss events re-attach the volume to a surviving node."
  type        = string
  default     = ""
}

variable "storage_size" {
  description = "PVC size for the MinIO data volume. Sized by what's archived — recordings dominate (typical sip-recorder WAV is ~1 MB / minute of call). Bump when archival cardinality grows."
  type        = string
  default     = "50Gi"
}

variable "node_selector" {
  description = "Node selector for the MinIO pod. Empty = scheduler picks. Pin to the `stateful` tier on a single-node-PV cluster so the PVC's local data dir is always reachable."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the MinIO pod. Empty = un-tainted nodes only."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}

variable "distributed" {
  description = "Optional distributed MinIO topology — `enabled = true` switches the module from a single-replica `Deployment` + one PVC to a `StatefulSet` with N replicas, each backed by its own PVC, with a headless Service for pod-to-pod traffic and `MINIO_VOLUMES` pointing at the per-pod hostnames so MinIO erasure-codes objects across the pool. The minimum legal `replica_count` is 4 (MinIO erasure coding requires at least 4 disks); `5` matches a single-pod-per-node spread on this 5-node cluster. Per-pod `storage_size` (set on `var.storage_size`) — total raw capacity is `storage_size × replica_count`, usable capacity is roughly `(replica_count - parity) × storage_size` (default parity 1, so 4 of 5 = 80% efficient on a 5-pod cluster). Anti-affinity spreads pods one-per-node by `kubernetes.io/hostname`. Empty / `enabled = false` keeps the standalone Deployment shape unchanged. Optional `hostpath_pvs` block opts into operator-pinned static `PersistentVolume`s (one per replica) backed by `hostPath` on a specific node — engine emits the PVs with `claimRef` pre-binding to the StatefulSet's `data-minio-<N>` PVCs, MinIO's app-layer erasure coding handles HA, no dynamic provisioner / Longhorn replication double-redundancy. When set: `node_hosts` is the per-replica hostname pin (length must equal `replica_count`) and `base_path` is the parent dir on each node — pod N gets `<base_path>/<N>` with `hostPath.type: DirectoryOrCreate`, kubelet auto-mkdir's at first attach. When omitted, the StatefulSet falls back to dynamic PVCs via `var.storage_class`."
  type = object({
    enabled       = optional(bool, false)
    replica_count = optional(number, 4)
    hostpath_pvs = optional(object({
      base_path  = string
      node_hosts = list(string)
    }))
  })
  default = {}
  validation {
    condition     = !try(var.distributed.enabled, false) || try(var.distributed.replica_count, 4) >= 4
    error_message = "distributed.replica_count must be at least 4 — MinIO erasure coding requires 4+ disks."
  }
  validation {
    condition     = try(var.distributed.hostpath_pvs, null) == null || length(try(var.distributed.hostpath_pvs.node_hosts, [])) == try(var.distributed.replica_count, 4)
    error_message = "distributed.hostpath_pvs.node_hosts length must equal distributed.replica_count — one hostname per replica."
  }
}

variable "buckets" {
  description = "Buckets the engine pre-creates and exposes via per-bucket Secrets. Map key is the bucket name (must match S3 naming rules: lowercase + dash). Each entry: `consumer_namespace` (where the engine emits the credentials Secret — engine assumes the namespace already exists), `secret_name` (the Secret's name in that namespace), `region` (string the SDK expects in `S3_REGION`; MinIO ignores it but boto3 / aws-sdk-go demand a value — default `auto` is universally accepted). Each bucket gets a dedicated MinIO service-account key — leakage of one Secret limits blast radius to that bucket. Empty map = MinIO server runs but no buckets are pre-created (unusual; only fits an operator who'll manage buckets externally)."
  type = map(object({
    consumer_namespace = string
    secret_name        = string
    region             = optional(string, "auto")
  }))
  default = {}
}

# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances             = var.enabled ? toset(["enabled"]) : toset([])
  standalone_instances  = (var.enabled && !try(var.distributed.enabled, false)) ? toset(["enabled"]) : toset([])
  distributed_instances = (var.enabled && try(var.distributed.enabled, false)) ? toset(["enabled"]) : toset([])
  bucket_targets        = var.enabled ? var.buckets : {}

  service_name          = "minio"
  headless_service_name = "minio-headless"
  api_port              = 9000
  console_port          = 9001
  endpoint              = "http://${local.service_name}.${var.namespace}.svc.cluster.local:${local.api_port}"

  # MINIO_VOLUMES env in distributed mode points at the per-pod
  # hostnames inside the headless Service. Bash brace-expansion
  # syntax — MinIO parses `{0...N-1}` natively into N peer URLs.
  distributed_volumes = try(var.distributed.enabled, false) ? "http://${local.service_name}-{0...${try(var.distributed.replica_count, 4) - 1}}.${local.headless_service_name}.${var.namespace}.svc.cluster.local/data" : ""

  # Static-PV (hostPath, operator-pinned) targets — one per replica
  # when `distributed.hostpath_pvs` is set. Indexed by replica
  # ordinal so the resource for_each lines up with the
  # StatefulSet's `data-minio-<N>` PVC naming scheme.
  static_pv_enabled = var.enabled && try(var.distributed.enabled, false) && try(var.distributed.hostpath_pvs, null) != null
  static_pv_targets = local.static_pv_enabled ? {
    for i in range(var.distributed.replica_count) :
    tostring(i) => {
      node = var.distributed.hostpath_pvs.node_hosts[i]
      path = "${var.distributed.hostpath_pvs.base_path}/${i}"
    }
  } : {}
}

# ── Root credentials ───────────────────────────────────────────────────────

resource "random_password" "root_user" {
  for_each = local.instances

  length  = 24
  special = false
}

resource "random_password" "root_password" {
  for_each = local.instances

  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "root" {
  for_each = local.instances

  metadata {
    name      = "minio-root"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "minio"
      "app.kubernetes.io/component" = "root-credentials"
    }
  }

  data = {
    MINIO_ROOT_USER     = random_password.root_user["enabled"].result
    MINIO_ROOT_PASSWORD = random_password.root_password["enabled"].result
  }
}

# ── PVC (standalone mode only — distributed uses volumeClaimTemplates) ────

resource "kubernetes_persistent_volume_claim_v1" "minio" {
  for_each = local.standalone_instances

  metadata {
    name      = "minio-data"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class != "" ? var.storage_class : null

    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
}

# ── Server: standalone Deployment (single-replica path) ───────────────────

resource "kubernetes_deployment_v1" "minio" {
  for_each = local.standalone_instances

  metadata {
    name      = "minio"
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = "minio" }
  }

  spec {
    replicas = 1

    strategy {
      # PVC is RWO so a rolling update would deadlock on the
      # in-flight pod still holding the lock. Recreate is fine for
      # an archive workload — a few seconds of unavailability on
      # operator-driven applies, no traffic loss in the common
      # write-then-read flow.
      type = "Recreate"
    }

    selector {
      match_labels = { "app.kubernetes.io/name" = "minio" }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "minio" }
      }

      spec {
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        container {
          name  = "minio"
          image = var.image
          args = [
            "server",
            "/data",
            "--address",
            ":${local.api_port}",
            "--console-address",
            ":${local.console_port}",
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.root["enabled"].metadata[0].name
            }
          }

          port {
            name           = "api"
            container_port = local.api_port
          }
          port {
            name           = "console"
            container_port = local.console_port
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/minio/health/ready"
              port = local.api_port
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/minio/health/live"
              port = local.api_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.minio["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Server: distributed StatefulSet (4+ replicas with erasure coding) ─────
#
# Each replica gets its own PVC via volumeClaimTemplates. Pods talk
# to one another via the headless Service (`minio-headless`) at
# `minio-{0..N-1}.minio-headless.<ns>.svc.cluster.local`. MinIO
# parses `MINIO_VOLUMES=http://minio-{0...N-1}...` into N peer
# URLs at boot, sets up the erasure-coded ring, and refuses to
# accept writes until quorum (N/2 + 1) is healthy.

resource "kubernetes_service_v1" "minio_headless" {
  for_each = local.distributed_instances

  metadata {
    name      = local.headless_service_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "minio"
      "app.kubernetes.io/component" = "headless"
    }
  }

  spec {
    cluster_ip                  = "None"
    publish_not_ready_addresses = true
    selector                    = { "app.kubernetes.io/name" = "minio" }

    port {
      name        = "api"
      port        = local.api_port
      target_port = local.api_port
    }
  }
}

resource "kubernetes_stateful_set_v1" "minio" {
  for_each = local.distributed_instances

  metadata {
    name      = "minio"
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = "minio" }
  }

  spec {
    service_name = local.headless_service_name
    replicas     = var.distributed.replica_count
    # Pods come up in parallel — distributed MinIO requires every
    # peer reachable at boot to form the erasure-coded ring; a
    # serial OrderedReady would deadlock the first replica waiting
    # for peers that haven't started.
    pod_management_policy = "Parallel"

    selector {
      match_labels = { "app.kubernetes.io/name" = "minio" }
    }

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "minio" }
      }

      spec {
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        # Spread replicas one-per-node — required for HA: with
        # erasure coding `N+1` survives one disk loss, but only
        # if disks are on distinct nodes. `requiredDuringScheduling`
        # blocks scheduling on a node that already hosts a peer.
        affinity {
          pod_anti_affinity {
            required_during_scheduling_ignored_during_execution {
              label_selector {
                match_labels = { "app.kubernetes.io/name" = "minio" }
              }
              topology_key = "kubernetes.io/hostname"
            }
          }
        }

        container {
          name  = "minio"
          image = var.image
          args = [
            "server",
            "--address",
            ":${local.api_port}",
            "--console-address",
            ":${local.console_port}",
          ]

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.root["enabled"].metadata[0].name
            }
          }

          env {
            name  = "MINIO_VOLUMES"
            value = local.distributed_volumes
          }

          port {
            name           = "api"
            container_port = local.api_port
          }
          port {
            name           = "console"
            container_port = local.console_port
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            http_get {
              path = "/minio/health/ready"
              port = local.api_port
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }

          liveness_probe {
            http_get {
              path = "/minio/health/live"
              port = local.api_port
            }
            initial_delay_seconds = 60
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "1"
              memory = "1Gi"
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        # When `hostpath_pvs` is set, force-empty SC so the PVC
        # binds to one of the engine-emitted static PVs (also
        # SC-empty) by their pre-baked `claimRef` rather than
        # going through a dynamic provisioner. Otherwise honour
        # the operator's `var.storage_class` (Longhorn, local-path,
        # etc).
        storage_class_name = local.static_pv_enabled ? "" : (var.storage_class != "" ? var.storage_class : null)
        resources {
          requests = {
            storage = var.storage_size
          }
        }
      }
    }
  }
}

# ── Static hostPath PVs (operator-pinned per replica) ─────────────────────
#
# When `distributed.hostpath_pvs` is set, engine pre-creates one PV
# per replica with `hostPath` to a fixed dir on a specific node.
# `claimRef` pins each PV to the StatefulSet's `data-minio-<N>` PVC
# so binding is exact (no race with other PVCs in the namespace
# also requesting an empty-SC RWO volume). `nodeAffinity` makes the
# scheduler only place the consuming pod on the matching node.
# `hostPath.type = DirectoryOrCreate` — kubelet auto-mkdir's the
# parent path on first attach; operator does NOT pre-mkdir on
# every node manually.

resource "kubernetes_persistent_volume_v1" "minio_static" {
  for_each = local.static_pv_targets

  metadata {
    name = "minio-${each.key}"
    labels = {
      "app.kubernetes.io/name"      = "minio"
      "app.kubernetes.io/component" = "static-pv"
      "platform.minio.replica"      = each.key
    }
  }

  spec {
    capacity = {
      storage = var.storage_size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    # Empty SC matches the StatefulSet's PVC template above when
    # static-PV mode is on. Don't omit — `null` would inherit the
    # cluster-default SC and break the bind.
    storage_class_name = ""

    persistent_volume_source {
      host_path {
        path = each.value.path
        type = "DirectoryOrCreate"
      }
    }

    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [each.value.node]
          }
        }
      }
    }

    claim_ref {
      namespace = var.namespace
      name      = "data-minio-${each.key}"
    }
  }
}

# ── Service ────────────────────────────────────────────────────────────────
#
# Single ClusterIP entry point — selects MinIO pods regardless of
# whether they're emitted from the standalone Deployment or the
# distributed StatefulSet (label `app.kubernetes.io/name=minio` on
# both). Consumers always hit `minio.<ns>.svc.cluster.local:9000`,
# the topology change is transparent.

resource "kubernetes_service_v1" "minio" {
  for_each = local.instances

  metadata {
    name      = local.service_name
    namespace = var.namespace
    labels    = { "app.kubernetes.io/name" = "minio" }
  }

  spec {
    selector = { "app.kubernetes.io/name" = "minio" }

    port {
      name        = "api"
      port        = local.api_port
      target_port = local.api_port
    }
    port {
      name        = "console"
      port        = local.console_port
      target_port = local.console_port
    }
  }
}

# ── Per-bucket access keys ─────────────────────────────────────────────────
#
# MinIO supports per-user access keys via service accounts. Engine
# generates one (access_key, secret_key) pair per bucket, hands the
# pair to a Job that mc-creates the user + bucket + read/write
# policy + svcacct binding. The pair lands as a Secret in the
# consumer namespace.

resource "random_password" "bucket_access_key" {
  for_each = local.bucket_targets

  length  = 20
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "random_password" "bucket_secret_key" {
  for_each = local.bucket_targets

  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "bucket" {
  for_each = local.bucket_targets

  metadata {
    name      = each.value.secret_name
    namespace = each.value.consumer_namespace
    labels = {
      "app.kubernetes.io/name"      = "minio"
      "app.kubernetes.io/component" = "bucket-credentials"
      "platform.bucket"             = each.key
    }
  }

  data = {
    S3_ACCESS_KEY_ID     = random_password.bucket_access_key[each.key].result
    S3_SECRET_ACCESS_KEY = random_password.bucket_secret_key[each.key].result
    S3_ENDPOINT          = local.endpoint
    S3_REGION            = each.value.region
    S3_BUCKET            = each.key
    S3_PATH_STYLE        = "true"
  }
}

# ── Bucket provisioner Job ─────────────────────────────────────────────────
#
# One Job per apply that creates buckets + service accounts + RW
# policies. Idempotent — `mc mb --ignore-existing` and
# `mc admin user svcacct add` skip when present, errors propagate
# only on real misconfig. Job runs to completion and is replaced on
# every apply that touches `buckets:` (the manifest's checksum
# changes, kubernetes_job_v1 re-creates).

resource "kubernetes_job_v1" "buckets" {
  for_each = length(local.bucket_targets) > 0 ? local.instances : toset([])

  depends_on = [
    kubernetes_deployment_v1.minio,
    kubernetes_stateful_set_v1.minio,
    kubernetes_service_v1.minio,
  ]

  metadata {
    name      = "minio-buckets-${formatdate("YYYYMMDDhhmmss", timestamp())}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = "minio"
      "app.kubernetes.io/component" = "bucket-provisioner"
    }
  }

  spec {
    backoff_limit              = 4
    ttl_seconds_after_finished = 600

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "minio-buckets" }
      }

      spec {
        restart_policy = "OnFailure"

        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        container {
          name  = "mc"
          image = var.mc_image

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.root["enabled"].metadata[0].name
            }
          }

          env {
            name  = "MINIO_ENDPOINT"
            value = local.endpoint
          }

          dynamic "env" {
            for_each = local.bucket_targets
            content {
              name  = "BUCKET_${replace(upper(env.key), "-", "_")}_AK"
              value = random_password.bucket_access_key[env.key].result
            }
          }

          dynamic "env" {
            for_each = local.bucket_targets
            content {
              name  = "BUCKET_${replace(upper(env.key), "-", "_")}_SK"
              value = random_password.bucket_secret_key[env.key].result
            }
          }

          command = ["/bin/sh", "-eu", "-c"]
          args = [
            join("\n", concat(
              [
                "until mc alias set local \"$MINIO_ENDPOINT\" \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1; do echo 'waiting for minio'; sleep 2; done",
                "echo 'minio reachable, provisioning buckets'",
              ],
              [
                for name, _ in local.bucket_targets :
                join("\n", [
                  "BUCKET=\"${name}\"",
                  "AK=\"$BUCKET_${replace(upper(name), "-", "_")}_AK\"",
                  "SK=\"$BUCKET_${replace(upper(name), "-", "_")}_SK\"",
                  "mc mb --ignore-existing local/\"$BUCKET\"",
                  "POLICY_DOC=$(mktemp)",
                  "cat > \"$POLICY_DOC\" <<EOF",
                  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:*\"],\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"]}]}",
                  "EOF",
                  "POLICY_NAME=\"bucket-rw-$BUCKET\"",
                  "mc admin policy create local \"$POLICY_NAME\" \"$POLICY_DOC\" 2>/dev/null || mc admin policy update local \"$POLICY_NAME\" \"$POLICY_DOC\"",
                  "mc admin user svcacct add local \"$MINIO_ROOT_USER\" --access-key \"$AK\" --secret-key \"$SK\" --policy \"$POLICY_DOC\" 2>/dev/null || mc admin user svcacct edit local \"$AK\" --policy \"$POLICY_DOC\"",
                  "echo \"$BUCKET ready\"",
                ])
              ],
            ))
          ]

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "5m"
  }
}

# ── Outputs ────────────────────────────────────────────────────────────────

output "enabled" {
  description = "Whether the module emitted any resources."
  value       = var.enabled
}

output "endpoint" {
  description = "Cluster-internal S3 API URL. Empty when disabled."
  value       = var.enabled ? local.endpoint : ""
}

output "service_name" {
  description = "Service name for the MinIO API. Empty when disabled."
  value       = var.enabled ? local.service_name : ""
}

output "bucket_secret_names" {
  description = "Map of bucket name → emitted Secret name (in the consumer namespace). Empty when no buckets configured or module disabled."
  value       = { for k, v in local.bucket_targets : k => v.secret_name }
}
