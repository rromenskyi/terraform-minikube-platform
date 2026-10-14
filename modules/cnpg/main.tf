# CloudNativePG — a highly available Postgres cluster run by an operator.
#
# One primary and streaming replicas on different nodes. When the primary's
# node fails, the operator promotes the most advanced replica and re-points
# the `<name>-rw` Service at it; a returning node rejoins as a replica. The
# decision runs through the Kubernetes API, so the etcd quorum, not the
# Postgres instances, settles who the primary is.
#
# With an S3-compatible bucket configured, the Barman Cloud plugin archives
# every WAL segment and takes scheduled base backups, so the cluster can be
# restored to any point inside the retention window.

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

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  tags = module.label.tags

  # Only the non-sensitive inputs decide whether backups are on: `for_each`
  # rejects values derived from sensitive ones. Missing credentials with a
  # bucket set show up as a failing archiver (and its alert).
  backup_configured = var.enabled && var.backup_bucket != "" && var.backup_endpoint != ""
  backups           = local.backup_configured ? toset(["enabled"]) : toset([])

  plugin_name       = "barman-cloud.cloudnative-pg.io"
  object_store_name = "${var.name}-backup"

  superuser_secret_name = "${var.name}-superuser"

  # `preferred` keeps writes going when no replica is healthy; `required`
  # would stop them, which on a two-instance cluster means any replica
  # outage stops the database.
  synchronous = var.synchronous && var.instances > 1 ? {
    synchronous = {
      method         = "any"
      number         = 1
      dataDurability = "preferred"
    }
  } : {}

  node_affinity = length(var.nodes) > 0 ? {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [{
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = var.nodes
          }]
        }]
      }
    }
  } : {}

  backup_plugin = local.backup_configured ? {
    plugins = [{
      name          = local.plugin_name
      isWALArchiver = true
      parameters    = { barmanObjectName = local.object_store_name }
    }]
  } : {}

  # Labels the cluster's Prometheus selects PodMonitors and PrometheusRules by.
  monitoring_labels = merge(local.tags, var.prometheus_selector_labels)
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = var.name
  tags = {
    "app.kubernetes.io/component" = "cnpg"
  }
}

# ── Operator and backup plugin ─────────────────────────────────────────────

resource "helm_release" "operator" {
  for_each = local.instances

  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = var.operator_chart_version
  namespace        = var.operator_namespace
  create_namespace = true
  # Helm keeps one Secret per revision with the full rendered manifest.
  max_history = 3

  values = [yamlencode({
    monitoring = {
      podMonitorEnabled          = true
      podMonitorAdditionalLabels = var.prometheus_selector_labels
      grafanaDashboard = {
        create = true
      }
    }
  })]
}

# The plugin registers itself with the operator through a Service in the
# operator's namespace, so it must be installed there, after the operator.
# Its TLS certificates come from cert-manager.
resource "helm_release" "barman_plugin" {
  for_each = local.instances

  depends_on = [helm_release.operator]

  name        = "barman-cloud"
  repository  = "https://cloudnative-pg.github.io/charts"
  chart       = "plugin-barman-cloud"
  version     = var.barman_plugin_chart_version
  namespace   = var.operator_namespace
  max_history = 3
}

# ── Credentials ────────────────────────────────────────────────────────────

# CloudNativePG reads the superuser password from a basic-auth Secret and
# keeps the `postgres` role in sync with it.
resource "kubernetes_secret_v1" "superuser" {
  for_each = local.instances

  metadata {
    name      = local.superuser_secret_name
    namespace = var.namespace
    labels    = local.tags
  }

  type = "kubernetes.io/basic-auth"
  data = {
    username = "postgres"
    password = var.superuser_password
    # The key the official `postgres` image and the platform's database
    # setup Jobs read, so they can switch to this Secret unchanged.
    POSTGRES_PASSWORD = var.superuser_password
  }
}

resource "kubernetes_secret_v1" "backup_credentials" {
  for_each = local.backups

  metadata {
    name      = "${var.name}-backup-credentials"
    namespace = var.namespace
    labels    = local.tags
  }

  data = {
    ACCESS_KEY_ID     = var.backup_access_key_id
    ACCESS_SECRET_KEY = var.backup_secret_access_key
  }
}

# ── Backup target ──────────────────────────────────────────────────────────

resource "kubectl_manifest" "object_store" {
  for_each = local.backups

  depends_on = [helm_release.barman_plugin]

  yaml_body = yamlencode({
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata = {
      name      = local.object_store_name
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      retentionPolicy = var.backup_retention
      configuration = {
        destinationPath = "s3://${var.backup_bucket}/${var.backup_prefix}/"
        endpointURL     = var.backup_endpoint
        s3Credentials = {
          accessKeyId     = { name = kubernetes_secret_v1.backup_credentials["enabled"].metadata[0].name, key = "ACCESS_KEY_ID" }
          secretAccessKey = { name = kubernetes_secret_v1.backup_credentials["enabled"].metadata[0].name, key = "ACCESS_SECRET_KEY" }
        }
        wal  = { compression = "gzip" }
        data = { compression = "gzip" }
      }
      # Newer boto3 sends integrity checksums that some S3-compatible stores
      # (Backblaze B2 among them) reject with an `x-amz-content-sha256`
      # error; only send them where the API requires it.
      # plugin-barman-cloud issue #393.
      instanceSidecarConfiguration = {
        resources = {
          requests = var.backup_sidecar_resources.requests
          limits   = var.backup_sidecar_resources.limits
        }
        env = [
          { name = "AWS_REQUEST_CHECKSUM_CALCULATION", value = "when_required" },
          { name = "AWS_RESPONSE_CHECKSUM_VALIDATION", value = "when_required" },
        ]
      }
    }
  })
}

# ── Cluster ────────────────────────────────────────────────────────────────

resource "kubectl_manifest" "cluster" {
  for_each = local.instances

  depends_on = [helm_release.operator, helm_release.barman_plugin, kubectl_manifest.object_store]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.tags
    }
    spec = merge({
      instances = var.instances
      imageName = var.image

      # Tools that log in as `postgres` (database setup Jobs, dumps) keep
      # working; the operator disables this access by default.
      enableSuperuserAccess = true
      superuserSecret       = { name = kubernetes_secret_v1.superuser["enabled"].metadata[0].name }

      bootstrap = {
        initdb = {
          # Page checksums catch corruption the storage layer did not.
          # They can only be chosen when the cluster is created.
          dataChecksums = true
        }
      }

      storage = {
        storageClass = var.storage_class
        size         = var.storage_size
      }

      resources = {
        requests = var.resources.requests
        limits   = var.resources.limits
      }

      postgresql = merge({ parameters = var.parameters }, local.synchronous)

      affinity = merge({
        enablePodAntiAffinity = true
        podAntiAffinityType   = "required"
        topologyKey           = "kubernetes.io/hostname"
      }, local.node_affinity)
    }, local.backup_plugin)
  })
}

resource "kubectl_manifest" "scheduled_backup" {
  for_each = local.backups

  depends_on = [kubectl_manifest.cluster]

  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata = {
      name      = "${var.name}-daily"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      schedule             = var.backup_schedule
      cluster              = { name = var.name }
      backupOwnerReference = "self"
      method               = "plugin"
      pluginConfiguration  = { name = local.plugin_name }
      # A first base backup right away: until one exists, the WAL archive
      # alone cannot restore anything.
      immediate = true
    }
  })
}

# ── Monitoring ─────────────────────────────────────────────────────────────

# The operator deprecated `spec.monitoring.enablePodMonitor`, so the
# instances' PodMonitor is declared here.
resource "kubectl_manifest" "pod_monitor" {
  for_each = local.instances

  depends_on = [kubectl_manifest.cluster]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels    = local.monitoring_labels
    }
    spec = {
      selector = {
        matchLabels = {
          "cnpg.io/cluster" = var.name
          "cnpg.io/podRole" = "instance"
        }
      }
      podMetricsEndpoints = [{ port = "metrics" }]
    }
  })
}

resource "kubectl_manifest" "prometheus_rule" {
  for_each = local.instances

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "${var.name}-cnpg"
      namespace = var.namespace
      labels    = local.monitoring_labels
    }
    spec = {
      groups = [{
        name = "cnpg-${var.namespace}-${var.name}"
        rules = concat([
          {
            alert = "CNPGInstancesMissing"
            # `or vector(0)`: with every instance down there are no series
            # left to count.
            expr   = "(count(cnpg_collector_up{namespace=\"${var.namespace}\",pod=~\"${var.name}-[0-9]+\"} == 1) or vector(0)) < ${var.instances}"
            for    = "5m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Postgres cluster ${var.namespace}/${var.name} runs fewer than ${var.instances} instances"
              description = "An instance is down or not ready; the cluster has less redundancy than configured, or no primary at all."
            }
          },
          {
            alert  = "CNPGReplicationLag"
            expr   = "max(cnpg_pg_replication_lag{namespace=\"${var.namespace}\",pod=~\"${var.name}-[0-9]+\"}) > 300"
            for    = "5m"
            labels = { severity = "warning" }
            annotations = {
              summary     = "Postgres cluster ${var.namespace}/${var.name}: a replica is more than 5 minutes behind"
              description = "A failover now would lose the replica's missing transactions."
            }
          },
          ], local.backup_configured ? [{
            alert  = "CNPGWALArchivingFailing"
            expr   = "max(cnpg_pg_stat_archiver_last_failed_time{namespace=\"${var.namespace}\",pod=~\"${var.name}-[0-9]+\"} - cnpg_pg_stat_archiver_last_archived_time{namespace=\"${var.namespace}\",pod=~\"${var.name}-[0-9]+\"}) > 1"
            for    = "10m"
            labels = { severity = "critical" }
            annotations = {
              summary     = "Postgres cluster ${var.namespace}/${var.name} fails to archive WAL"
              description = "The last archive attempt failed after the last success: point-in-time recovery stops at the last archived segment, and WAL piles up on the primary's disk."
            }
        }] : [])
      }]
    }
  })
}
