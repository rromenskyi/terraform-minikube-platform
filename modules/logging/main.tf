terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

# =============================================================================
# Cluster log aggregation — VictoriaLogs (store/query) + Vector (collector)
# =============================================================================
#
# Replaces "logs only live on the node until the kubelet rotates them away
# (50 MiB/container, gone on pod delete)" with a real, time-retained,
# searchable log store:
#
#   every node:  /var/log/pods/*  →  Vector DaemonSet (kubernetes_logs,
#                                     auto-enriched with pod/ns/labels)
#                                          │ HTTP ingest :9428
#                                          ▼
#                                VictoriaLogs (1 pod, -retentionPeriod,
#                                     data on a Longhorn PV)
#                                          ▲
#                                Grafana (kube-prometheus-stack) ── LogsQL
#                                     datasource (sidecar-discovered ConfigMap)
#
# Everything lands in the `monitoring` namespace so the Grafana datasource
# sidecar picks up the ConfigMap with no cross-namespace plumbing. VictoriaLogs
# is a single static binary (low RAM); Vector runs on every node (tolerates all
# taints). Alerting (vmalert + Alertmanager email receiver) is layered on top
# separately — this module is the store + collector + datasource.

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
  tags      = module.label.tags

  vl_name     = "victorialogs"
  vector_name = "vector"

  # kubernetes_logs emits `.message` / `.timestamp` / `.kubernetes.*`;
  # map those onto VictoriaLogs' message/time/stream fields at ingest.
  vector_config = yamlencode({
    data_dir = "/vector-data-dir"
    api      = { enabled = false }
    sources = {
      k8s = { type = "kubernetes_logs" }
    }
    sinks = {
      vlogs = {
        type        = "elasticsearch"
        inputs      = ["k8s"]
        endpoints   = ["http://${local.vl_name}:9428/insert/elasticsearch/"]
        mode        = "bulk"
        api_version = "v8"
        compression = "gzip"
        healthcheck = { enabled = false }
        query = {
          _msg_field     = "message"
          _time_field    = "timestamp"
          _stream_fields = "kubernetes.pod_namespace,kubernetes.pod_name,kubernetes.container_name"
        }
      }
    }
  })
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "logging"
  tags = {
    "app.kubernetes.io/part-of" = "observability"
  }
}

# ── VictoriaLogs — store + query API ─────────────────────────────────────────

resource "kubernetes_service_v1" "victorialogs" {
  for_each = local.instances

  metadata {
    name      = local.vl_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vl_name })
  }

  spec {
    selector = { app = local.vl_name }
    port {
      name        = "http"
      port        = 9428
      target_port = 9428
    }
  }
}

resource "kubernetes_stateful_set_v1" "victorialogs" {
  for_each = local.instances

  metadata {
    name      = local.vl_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vl_name })
  }

  spec {
    replicas     = 1
    service_name = local.vl_name
    selector {
      match_labels = { app = local.vl_name }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = local.vl_name })
      }

      spec {
        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          run_as_non_root = true
          fs_group        = 1000
        }

        node_selector = var.node_selector

        container {
          name  = local.vl_name
          image = var.victorialogs_image

          args = [
            "-storageDataPath=/vlogs",
            "-retentionPeriod=${var.retention_period}",
            "-httpListenAddr=:9428",
          ]

          port {
            name           = "http"
            container_port = 9428
          }

          volume_mount {
            name       = "data"
            mount_path = "/vlogs"
          }

          resources {
            requests = var.victorialogs_resources.requests
            limits   = var.victorialogs_resources.limits
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 9428
            }
            initial_delay_seconds = 5
            period_seconds        = 15
          }

          security_context {
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.storage_class != "" ? var.storage_class : null
        resources {
          requests = { storage = var.storage_size }
        }
      }
    }
  }
}

# ── Vector — per-node log collector (DaemonSet) ──────────────────────────────

resource "kubernetes_service_account_v1" "vector" {
  for_each = local.instances

  metadata {
    name      = local.vector_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vector_name })
  }
}

resource "kubernetes_cluster_role_v1" "vector" {
  for_each = local.instances

  metadata {
    name   = "${var.namespace}-vector-log-reader"
    labels = local.tags
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "pods", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "vector" {
  for_each = local.instances

  metadata {
    name   = "${var.namespace}-vector-log-reader"
    labels = local.tags
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.vector["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.vector["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_config_map_v1" "vector" {
  for_each = local.instances

  metadata {
    name      = "${local.vector_name}-config"
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vector_name })
  }

  data = {
    "vector.yaml" = local.vector_config
  }
}

resource "kubernetes_daemon_set_v1" "vector" {
  for_each = local.instances

  metadata {
    name      = local.vector_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vector_name })
  }

  spec {
    selector {
      match_labels = { app = local.vector_name }
    }

    template {
      metadata {
        labels      = merge(local.tags, { app = local.vector_name })
        annotations = { "checksum/config" = sha256(local.vector_config) }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.vector["enabled"].metadata[0].name

        # Reads /var/log/pods/* which are root-owned (mode 0600) — the
        # collector must run as root to tail every pod's logs.
        security_context {
          run_as_user = 0
        }

        dynamic "toleration" {
          for_each = var.vector_tolerations
          content {
            key      = try(toleration.value.key, null)
            operator = try(toleration.value.operator, null)
            value    = try(toleration.value.value, null)
            effect   = try(toleration.value.effect, null)
          }
        }

        container {
          name  = local.vector_name
          image = var.vector_image
          args  = ["--config", "/etc/vector/vector.yaml"]

          env {
            name = "VECTOR_SELF_NODE_NAME"
            value_from {
              field_ref { field_path = "spec.nodeName" }
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/vector"
            read_only  = true
          }
          volume_mount {
            name       = "var-log"
            mount_path = "/var/log"
            read_only  = true
          }
          volume_mount {
            name       = "data-dir"
            mount_path = "/vector-data-dir"
          }

          resources {
            requests = var.vector_resources.requests
            limits   = var.vector_resources.limits
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.vector["enabled"].metadata[0].name
          }
        }
        volume {
          name = "var-log"
          host_path {
            path = "/var/log"
          }
        }
        volume {
          name = "data-dir"
          host_path {
            path = "/var/lib/vector"
            type = "DirectoryOrCreate"
          }
        }
      }
    }
  }
}

# ── Grafana datasource — sidecar discovery ───────────────────────────────────
# The kube-prometheus-stack Grafana runs a datasource sidecar that watches
# this namespace for ConfigMaps labelled `grafana_datasource=1` and loads
# them. Registers VictoriaLogs via its native Grafana plugin
# (`victoriametrics-logs-datasource`, installed through the addons
# `monitoring_grafana_extra_values.plugins`), giving full LogsQL + the
# Explore field/time UI.

resource "kubernetes_config_map_v1" "grafana_datasource" {
  for_each = local.instances

  metadata {
    name      = "victorialogs-datasource"
    namespace = var.namespace
    labels    = merge(local.tags, { grafana_datasource = "1" })
  }

  data = {
    "victorialogs.yaml" = yamlencode({
      apiVersion = 1
      datasources = [{
        name      = "VictoriaLogs"
        type      = "victoriametrics-logs-datasource"
        access    = "proxy"
        url       = "http://${local.vl_name}:9428"
        isDefault = false
        editable  = true
      }]
    })
  }
}
