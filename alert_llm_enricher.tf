# AI alert enrichment — asks a local LLM (the shared Ollama, or an
# OpenAI-compatible server: `services.alert_llm_enrichment.api`) for a
# diagnosis + action plan for each firing log alert, emailed alongside (never
# instead of) the existing plain-text alert email. See modules/logging's
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
  alert_llm_enricher_model = (
    local.alert_llm_enrichment.model != "" ? local.alert_llm_enrichment.model : local.alert_llm_enrichment.ollama_model
  )

  alert_llm_enricher_runbook_path = (
    local.alert_llm_enrichment.runbook_file != "" ? "${path.module}/${local.alert_llm_enrichment.runbook_file}" : ""
  )
  alert_llm_enricher_runbook = (
    local.alert_llm_enricher_runbook_path == "" ? "" : (
      fileexists(local.alert_llm_enricher_runbook_path) ? file(local.alert_llm_enricher_runbook_path) : ""
    )
  )

  # Security digest: a loop inside the same pod (scripts/alert-llm-enricher.py,
  # run_security_digest) that reads trivy-operator's VulnerabilityReports.
  alert_llm_security_digest = (
    length(local.alert_llm_enrichment_instances) > 0
    && local.platform.services.security_scan.enabled
    && local.alert_llm_enrichment.security_digest_interval_hours > 0
    ? toset(["enabled"]) : toset([])
  )
  alert_llm_security_state_name = "${local.alert_llm_enricher_name}-security-state"

  # The push topic URL works like a password (anyone holding it can read and
  # post), so it reaches the pod through a Secret, not a plain env value.
  alert_llm_enricher_push = (
    length(local.alert_llm_enrichment_instances) > 0 && local.alert_llm_enrichment.push && local._alert_push_url != ""
    ? toset(["enabled"]) : toset([])
  )
}

resource "kubernetes_config_map_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances

  metadata {
    name      = local.alert_llm_enricher_name
    namespace = local.platform.services.logging.namespace
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "alert-llm-enricher" })
  }

  data = merge(
    { "enricher.py" = file("${path.module}/scripts/alert-llm-enricher.py") },
    local.alert_llm_enricher_runbook != "" ? { "runbook.md" = local.alert_llm_enricher_runbook } : {},
  )
}

resource "kubernetes_secret_v1" "alert_llm_enricher_push" {
  for_each = local.alert_llm_enricher_push

  metadata {
    name      = "${local.alert_llm_enricher_name}-push"
    namespace = local.platform.services.logging.namespace
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "alert-llm-enricher" })
  }

  data = {
    url = local._alert_push_url
  }
}

# ── RBAC: read-only access to real pod status, events and nodes ─────────────
# Log text alone doesn't carry a kernel OOM-kill: a SIGKILL'd process gets no
# chance to print "OOMKilled" itself — that reason/exit-code only exists in
# the pod's status (containerStatuses[].lastState.terminated) and in Warning
# events. Confirmed live: a real OOM-killed test pod's own stdout had no such
# text at all. Cluster-wide (not namespaced) because alerting pods can be in
# any namespace, not just this one — get/list only, no write. Nodes: the
# alerting pod's node state (Ready, pressure, cordoned, gone) is often the
# cause.

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
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get"]
  }
  dynamic "rule" {
    for_each = local.alert_llm_security_digest
    content {
      api_groups = ["aquasecurity.github.io"]
      resources  = ["vulnerabilityreports"]
      verbs      = ["list"]
    }
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

# ── Security digest state ───────────────────────────────────────────────────
# What the last digest reported, so a pod restart doesn't resend it and only
# changes trigger the next one. The enricher owns the content (it patches
# `state.json` after each digest), hence ignore_changes on data; the Role lets
# it read and patch this one ConfigMap and nothing else.

resource "kubernetes_config_map_v1" "alert_llm_security_state" {
  for_each = local.alert_llm_security_digest

  metadata {
    name      = local.alert_llm_security_state_name
    namespace = local.platform.services.logging.namespace
    labels    = merge(module.platform_label.tags, { "app.kubernetes.io/component" = "alert-llm-enricher" })
  }

  data = {}

  lifecycle {
    ignore_changes = [data]
  }
}

resource "kubernetes_role_v1" "alert_llm_security_state" {
  for_each = local.alert_llm_security_digest

  metadata {
    name      = local.alert_llm_security_state_name
    namespace = local.platform.services.logging.namespace
    labels    = module.platform_label.tags
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map_v1.alert_llm_security_state["enabled"].metadata[0].name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "alert_llm_security_state" {
  for_each = local.alert_llm_security_digest

  metadata {
    name      = local.alert_llm_security_state_name
    namespace = local.platform.services.logging.namespace
    labels    = module.platform_label.tags
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.alert_llm_security_state["enabled"].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.alert_llm_enricher["enabled"].metadata[0].name
    namespace = local.platform.services.logging.namespace
  }
}

resource "kubernetes_deployment_v1" "alert_llm_enricher" {
  for_each = local.alert_llm_enrichment_instances

  lifecycle {
    precondition {
      condition     = local.alert_llm_enricher_model != ""
      error_message = "services.alert_llm_enrichment.model (or its older name ollama_model) must be set when the enricher is enabled (with the shared Ollama, use the chat default model)."
    }
    precondition {
      condition     = contains(["ollama", "openai"], local.alert_llm_enrichment.api)
      error_message = "services.alert_llm_enrichment.api must be \"ollama\" or \"openai\"."
    }
    precondition {
      condition     = local.alert_llm_enricher_runbook_path == "" ? true : fileexists(local.alert_llm_enricher_runbook_path)
      error_message = "services.alert_llm_enrichment.runbook_file: ${local.alert_llm_enrichment.runbook_file} does not exist (path relative to the repository root)."
    }
    precondition {
      condition     = local.alert_llm_enrichment.api == "ollama" || local.alert_llm_enrichment.url != ""
      error_message = "services.alert_llm_enrichment.url is required when api is \"openai\" (base URL including /v1)."
    }
  }

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
          "checksum/runbook"     = sha256(local.alert_llm_enricher_runbook)
          # PUSH_URL is read from the Secret at container start only: a new
          # topic must roll the pod.
          "checksum/push-url" = sha256(length(local.alert_llm_enricher_push) > 0 ? local._alert_push_url : "")
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
            name  = "LLM_API"
            value = local.alert_llm_enrichment.api
          }
          env {
            name  = "LLM_URL"
            value = local.alert_llm_enrichment.url
          }
          env {
            name  = "LLM_MODEL"
            value = local.alert_llm_enricher_model
          }
          env {
            name  = "DIAGNOSIS_LANGUAGE"
            value = local.alert_llm_enrichment.language
          }
          env {
            name  = "LLM_MAX_TOKENS"
            value = tostring(local.alert_llm_enrichment.max_tokens)
          }
          env {
            name  = "PROMPT_CHAR_BUDGET"
            value = tostring(local.alert_llm_enrichment.prompt_char_budget)
          }
          env {
            name  = "ALERTMANAGER_URL"
            value = local.alert_llm_enrichment.alertmanager_url
          }
          env {
            name  = "NODE_POOL_LABEL"
            value = local.platform.node_pool_label
          }
          # 0 = the digest loop doesn't start.
          env {
            name  = "SECURITY_DIGEST_INTERVAL_SECONDS"
            value = length(local.alert_llm_security_digest) > 0 ? tostring(local.alert_llm_enrichment.security_digest_interval_hours * 3600) : "0"
          }
          env {
            name  = "SECURITY_DIGEST_REMINDER_SECONDS"
            value = tostring(local.alert_llm_enrichment.security_digest_reminder_days * 86400)
          }
          env {
            name  = "SECURITY_DIGEST_SEVERITIES"
            value = join(",", local.platform.services.security_scan.alert_severities)
          }
          env {
            name = "SECURITY_STATE_CONFIGMAP"
            # Through the resource, so the ConfigMap exists before the pod.
            value = try(kubernetes_config_map_v1.alert_llm_security_state["enabled"].metadata[0].name, "")
          }
          env {
            name  = "POD_NAMESPACE"
            value = local.platform.services.logging.namespace
          }
          dynamic "env" {
            for_each = kubernetes_secret_v1.alert_llm_enricher_push
            content {
              name = "PUSH_URL"
              value_from {
                secret_key_ref {
                  name = env.value.metadata[0].name
                  key  = "url"
                }
              }
            }
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
