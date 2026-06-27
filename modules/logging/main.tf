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
  # Alerting (vmalert + Alertmanager receiver) only when an alert email is set.
  alerting = var.enabled && var.alert_email != "" ? toset(["enabled"]) : toset([])
  tags     = module.label.tags

  vl_name      = "victorialogs"
  vector_name  = "vector"
  vmalert_name = "vmalert"

  # vmalert rule file: one `type: vlogs` group whose rules evaluate the
  # operator's LogsQL `stats count() | filter` queries against VictoriaLogs.
  # Each alert carries `namespace = <this ns>` so the AlertmanagerConfig's
  # OnNamespace matcher routes it to the email receiver.
  vmalert_rules = yamlencode({
    groups = [{
      name     = "log-alerts"
      type     = "vlogs"
      interval = "1m"
      rules = [
        for k, r in var.alert_rules : {
          alert = k
          expr  = r.query
          for   = r.for
          labels = {
            severity  = r.severity
            namespace = var.namespace
            # Distinguishes log alerts from the built-in kube-prometheus-stack
            # metric alerts (which also carry namespace=monitoring) so the
            # email route matches ONLY these.
            alert_source = "log"
          }
          annotations = { summary = r.summary }
        }
      ]
    }]
  })

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

# ── Alerting — vmalert (LogsQL rules) → existing Alertmanager → email ─────────
# Only when `alert_email` is set. vmalert evaluates the `type: vlogs` rule
# group against VictoriaLogs' stats endpoint and fires to the kube-prometheus-
# stack Alertmanager; an AlertmanagerConfig adds the email receiver. The store
# + collector run with no alerting when this is empty.

resource "kubernetes_config_map_v1" "vmalert_rules" {
  for_each = local.alerting

  metadata {
    name      = "${local.vmalert_name}-rules"
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vmalert_name })
  }

  data = {
    "log-alerts.yaml" = local.vmalert_rules
  }
}

# vmalert had no Service — its alert Source/generator links fell back to the
# raw pod address (`vmalert-<hash>:8880`), which no browser can reach. This
# gives the UI a stable in-cluster name so a consumer can route a hostname to
# it (pair with `vmalert_external_url` so the generated links match).
resource "kubernetes_service_v1" "vmalert" {
  for_each = local.alerting

  metadata {
    name      = local.vmalert_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vmalert_name })
  }

  spec {
    selector = { app = local.vmalert_name }
    port {
      name        = "http"
      port        = 8880
      target_port = 8880
    }
  }
}

resource "kubernetes_deployment_v1" "vmalert" {
  for_each = local.alerting

  metadata {
    name      = local.vmalert_name
    namespace = var.namespace
    labels    = merge(local.tags, { app = local.vmalert_name })
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = local.vmalert_name }
    }

    template {
      metadata {
        labels      = merge(local.tags, { app = local.vmalert_name })
        annotations = { "checksum/rules" = sha256(local.vmalert_rules) }
      }

      spec {
        security_context {
          run_as_user     = 1000
          run_as_non_root = true
        }

        container {
          name  = local.vmalert_name
          image = var.vmalert_image

          args = concat([
            "-rule=/etc/vmalert/log-alerts.yaml",
            "-datasource.url=http://${local.vl_name}:9428",
            "-notifier.url=${var.alertmanager_url}",
            "-evaluationInterval=1m",
            ], var.vmalert_external_url != "" ? [
            # Browser-reachable base for the Source/generator links vmalert
            # stamps on alerts (the notification "Source" button). Omitted
            # when unset, so vmalert keeps its in-cluster pod-address default.
            "-external.url=${var.vmalert_external_url}",
          ] : [])

          port {
            name           = "http"
            container_port = 8880
          }

          volume_mount {
            name       = "rules"
            mount_path = "/etc/vmalert"
            read_only  = true
          }

          resources {
            requests = { cpu = "20m", memory = "64Mi" }
            limits   = { cpu = "200m", memory = "192Mi" }
          }

          security_context {
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }
        }

        volume {
          name = "rules"
          config_map {
            name = kubernetes_config_map_v1.vmalert_rules["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# Email receiver on the existing kube-prometheus-stack Alertmanager. The
# Alertmanager CR selects AlertmanagerConfigs cluster-wide (selector `{}`); the
# default `OnNamespace` matcher strategy scopes this to alerts labelled
# `namespace=<this ns>` — which the vmalert rules above all carry. Sends through
# the in-cluster Stalwart inbound listener (plaintext, in-cluster hop) to the
# operator's local mailbox; no relay-trust change or SMTP credentials.
resource "kubectl_manifest" "alertmanager_email" {
  for_each = local.alerting

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1alpha1"
    kind       = "AlertmanagerConfig"
    metadata = {
      name      = "log-alerts-email"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      route = {
        receiver       = "email"
        groupBy        = ["alertname"]
        groupWait      = "30s"
        groupInterval  = "5m"
        repeatInterval = "3h"
        # Only our log alerts (the OnNamespace strategy already injects a
        # `namespace=<ns>` matcher; this narrows to log alerts so the
        # built-in metric alerts in this namespace don't hit the receiver).
        matchers = [{
          name      = "alert_source"
          value     = "log"
          matchType = "="
        }]
      }
      receivers = [{
        name = "email"
        emailConfigs = [{
          to   = var.alert_email
          from = var.smtp_from
          # EHLO hostname — must be a valid FQDN or Stalwart rejects the
          # session with "550 Invalid EHLO domain" (the pod hostname isn't).
          hello        = var.smtp_hello
          smarthost    = var.smtp_smarthost
          requireTLS   = false
          sendResolved = true
        }]
      }]
    }
  })
}
