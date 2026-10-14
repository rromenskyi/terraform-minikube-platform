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

  superuser_secret_name = var.superuser_secret_name != "" ? var.superuser_secret_name : "${var.name}-superuser"

  # Labels the operator keeps on the current primary (moved on failover).
  primary_selector = { "cnpg.io/cluster" = var.name, "cnpg.io/instanceRole" = "primary" }
  services         = var.enabled && var.service_name != "" ? toset(["enabled"]) : toset([])

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

  # The operator reads only the `username` / `password` keys, not the type;
  # Opaque keeps the Secret compatible with clients of a former
  # single-instance server that read `POSTGRES_PASSWORD` from it.
  type = "Opaque"
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

# ── Client Service ─────────────────────────────────────────────────────────

# A Service under a name of the caller's choice (e.g. the name clients of a
# former server already use) that always selects the current primary, like
# the operator's own `<name>-rw`.
resource "kubernetes_service_v1" "primary" {
  for_each = local.services

  metadata {
    name      = var.service_name
    namespace = var.namespace
    labels    = local.tags
  }

  spec {
    selector = local.primary_selector

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
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

# ── One-off copy from another server ───────────────────────────────────────

locals {
  sync_runs = var.enabled && var.sync != null ? (var.sync.run != "" ? toset([var.sync.run]) : toset([])) : toset([])

  # Runs in the cluster's own image, so pg_dump matches the server version.
  sync_script = <<-EOT
    set -euo pipefail
    src() { PGPASSWORD="$SRC_PASSWORD" psql -h "$SRC_HOST" -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
    dst() { PGPASSWORD="$DST_PASSWORD" psql -h "$DST_HOST" -U postgres -X -v ON_ERROR_STOP=1 "$@"; }
    started=$(date +%s)

    dbs=$(src -d postgres -tAc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate AND datname <> 'postgres' ORDER BY 1")

    if [ "$MODE" = thaw ]; then
      for db in $dbs; do
        printf 'ALTER DATABASE :"db" CONNECTION LIMIT -1;\n' | src -d postgres -q -v db="$db"
      done
      echo "source thawed: $(echo $dbs | wc -w) databases accept connections again"
      exit 0
    fi

    # Roles before the freeze, while the source is unchanged. The target
    # manages its own `postgres` role; for a role that already exists
    # CREATE ROLE fails harmlessly and the ALTER ROLE after it still sets the
    # attributes and the password hash, so a rerun converges.
    PGPASSWORD="$SRC_PASSWORD" pg_dumpall -h "$SRC_HOST" -U postgres --roles-only \
      | grep -vE '^(CREATE|ALTER) ROLE postgres[ ;]' > /tmp/roles.sql
    PGPASSWORD="$DST_PASSWORD" psql -h "$DST_HOST" -U postgres -X -q -d postgres -f /tmp/roles.sql 2>&1 \
      | grep -v 'already exists' || true

    if [ "$MODE" = cutover ]; then
      # CONNECTION LIMIT binds every role but superusers, owners included,
      # so clients are locked out while pg_dump still connects.
      for db in $dbs; do
        printf 'ALTER DATABASE :"db" CONNECTION LIMIT 0;\nSELECT count(pg_terminate_backend(a.pid)) AS ended FROM pg_stat_activity a JOIN pg_roles r ON r.oid = a.usesysid WHERE a.datname = :%s AND NOT r.rolsuper;\n' "'db'" \
          | src -d postgres -q -tA -v db="$db" > /dev/null
      done
      echo "source frozen"
    fi

    for db in $dbs; do
      printf 'SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE datname = :%s AND pid <> pg_backend_pid();\n' "'db'" \
        | dst -d postgres -q -tA -v db="$db" > /dev/null
      PGPASSWORD="$SRC_PASSWORD" pg_dump -h "$SRC_HOST" -U postgres --create --clean --if-exists -d "$db" \
        | dst -d postgres -q > /dev/null
      # The copy carries the source's (possibly frozen) limit.
      printf 'ALTER DATABASE :"db" CONNECTION LIMIT -1;\n' | dst -d postgres -q -v db="$db"
      echo "copied $db"
    done

    rows() {
      "$1" -d "$2" -tA <<'SQL'
    SELECT format('%I.%I', table_schema, table_name) || ' ' ||
           (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
      FROM information_schema.tables
     WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
     ORDER BY 1;
    SQL
    }
    roles() { "$1" -d postgres -tAc "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_' AND rolname <> 'postgres' ORDER BY 1"; }

    differs=0
    missing=$(comm -23 <(roles src) <(roles dst))
    if [ -n "$missing" ]; then echo "roles missing on the target: $missing"; differs=1; fi
    for db in $dbs; do
      if ! diff <(rows src "$db") <(rows dst "$db") > /tmp/diff; then
        echo "row counts differ in $db:"; cat /tmp/diff; differs=1
      fi
    done

    echo "copied $(echo $dbs | wc -w) databases in $(( $(date +%s) - started ))s"
    if [ "$differs" = 1 ]; then
      if [ "$MODE" = cutover ]; then echo "verification FAILED"; exit 1; fi
      echo "differences above are expected while the source takes writes (rehearsal)"
    else
      echo "verification passed: roles and row counts match"
    fi
  EOT
}

resource "kubernetes_job_v1" "sync" {
  for_each = local.sync_runs

  depends_on = [kubectl_manifest.cluster]

  metadata {
    name      = "${var.name}-sync-${each.key}"
    namespace = var.namespace
    labels    = local.tags
  }

  spec {
    # A failed copy is rerun deliberately with a new `run` id, never
    # retried behind the operator's back.
    backoff_limit = 0

    template {
      metadata {
        labels = local.tags
      }

      spec {
        restart_policy = "Never"

        security_context {
          run_as_non_root = true
          run_as_user     = 26 # `postgres` in the CloudNativePG images
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "sync"
          image   = var.image
          command = ["/usr/bin/bash", "-c", local.sync_script]

          env {
            name  = "MODE"
            value = var.sync.mode
          }
          env {
            name  = "SRC_HOST"
            value = var.sync.source_host
          }
          env {
            name = "SRC_PASSWORD"
            value_from {
              secret_key_ref {
                name = var.sync.source_secret
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "DST_HOST"
            value = "${var.name}-rw.${var.namespace}.svc.cluster.local"
          }
          env {
            name = "DST_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.superuser["enabled"].metadata[0].name
                key  = "password"
              }
            }
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { cpu = "1", memory = "512Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "30m"
  }
}
