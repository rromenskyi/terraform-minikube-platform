# AI alert enrichment — asks the local Ollama model for a diagnosis + action
# plan for each firing log alert, emailed alongside (never instead of) the
# existing plain-text alert email. See modules/logging's
# `ai_enrichment_webhook_url` variable for why this is a second integration
# on the SAME Alertmanager receiver rather than a competing route.
#
# The consumer is scripts/alert-llm-enricher.py (stdlib-only Python), mounted
# from a ConfigMap onto a generic python image — no custom image build or
# registry needed for a script this size. Lives in the `logging` service's
# own namespace (monitoring) since it's tightly coupled to that pipeline
# (VictoriaLogs query API, the alert webhook itself); reaches Ollama and
# Stalwart cross-namespace like everything else on this single-trust-
# boundary cluster.

locals {
  alert_llm_enrichment = local.platform.services.alert_llm_enrichment

  # Only meaningful when logging's own alerting is wired up too — no alert
  # email means no vmalert/Alertmanager receiver to attach a webhook to.
  alert_llm_enrichment_instances = (
    local.alert_llm_enrichment.enabled && local.platform.services.logging.alert_email != ""
    ? toset(["enabled"]) : toset([])
  )

  alert_llm_enricher_name = "alert-llm-enricher"
}

resource "kubernetes_config_map_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances

  metadata {
    name      = local.alert_llm_enricher_name
    namespace = local.platform.services.logging.namespace
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "alert-llm-enricher" })
  }

  data = {
    "enricher.py" = file("${path.module}/scripts/alert-llm-enricher.py")
  }
}

# ── RBAC: read-only access to real pod status + events ──────────────────────
# Log text alone doesn't carry a kernel OOM-kill: a SIGKILL'd process gets no
# chance to print "OOMKilled" itself — that reason/exit-code only exists in
# the pod's status (containerStatuses[].lastState.terminated) and in Warning
# events. Confirmed live: a real OOM-killed test pod's own stdout had no such
# text at all. Cluster-wide (not namespaced) because alerting pods can be in
# any namespace, not just this one — get/list only, no write, no other
# resource kinds.

resource "kubernetes_service_account_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances
  metadata {
    name      = local.alert_llm_enricher_name
    namespace = local.platform.services.logging.namespace
    labels    = module.platform_label.tags
  }
}

resource "kubernetes_cluster_role_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances
  metadata {
    name   = local.alert_llm_enricher_name
    labels = module.platform_label.tags
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "events"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances
  metadata {
    name   = local.alert_llm_enricher_name
    labels = module.platform_label.tags
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.alert_llm_enricher["enabled"].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.alert_llm_enricher["enabled"].metadata[0].name
    namespace = local.platform.services.logging.namespace
  }
}

resource "kubernetes_deployment_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances

  metadata {
    name      = local.alert_llm_enricher_name
    namespace = local.platform.services.logging.namespace
    labels = merge(module.platform_label.tags, {
      "app.kubernetes.io/name"      = local.alert_llm_enricher_name
      "app.kubernetes.io/component" = "alert-llm-enricher"
    })
  }

  spec {
    replicas = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = local.alert_llm_enricher_name }
    }

    template {
      metadata {
        labels = merge(module.platform_label.tags, {
          "app.kubernetes.io/name"      = local.alert_llm_enricher_name
          "app.kubernetes.io/component" = "alert-llm-enricher"
        })
        annotations = {
          # Forces a rollout when the script content changes — a plain
          # ConfigMap update alone doesn't restart the pod to pick it up.
          "checksum/enricher-py" = sha256(file("${path.module}/scripts/alert-llm-enricher.py"))
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.alert_llm_enricher["enabled"].metadata[0].name

        security_context {
          run_as_user     = 1000
          run_as_non_root = true
        }

        container {
          name              = "enricher"
          image             = "python:3.13-alpine"
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/app/enricher.py"]

          env {
            name  = "ALERT_EMAIL_TO"
            value = local.platform.services.logging.alert_email
          }
          env {
            name  = "SMTP_FROM"
            value = local.alert_llm_enrichment.smtp_from
          }
          env {
            name  = "SMTP_HELLO"
            value = local.alert_llm_enrichment.smtp_hello
          }
          env {
            name  = "OLLAMA_MODEL"
            value = local.alert_llm_enrichment.ollama_model
          }

          port {
            name           = "http"
            container_port = 8080
          }

          volume_mount {
            name       = "script"
            mount_path = "/app"
            read_only  = true
          }

          resources {
            requests = { cpu = local.alert_llm_enrichment.cpu_request, memory = local.alert_llm_enrichment.memory_request }
            limits   = { cpu = local.alert_llm_enrichment.cpu_limit, memory = local.alert_llm_enrichment.memory_limit }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "script"
          config_map {
            name         = kubernetes_config_map_v1.alert_llm_enricher["enabled"].metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances

  metadata {
    name      = local.alert_llm_enricher_name
    namespace = local.platform.services.logging.namespace
    labels    = module.platform_label.tags
  }

  spec {
    selector = { "app.kubernetes.io/name" = local.alert_llm_enricher_name }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
