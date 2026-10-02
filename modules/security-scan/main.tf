# Continuous CVE scanning of platform-system container images.
#
# Upstream `trivy-operator` (Aqua Security,
# https://github.com/aquasecurity/trivy-operator) watches Pods in the
# allowlisted namespaces, scans each unique image and writes a
# `VulnerabilityReport` next to the workload. Reports expire after the
# chart's report TTL (24h) and are rescanned, so they always describe what
# is running now.
#
# Signal goes through the platform's monitoring stack, not a side channel:
# the operator's metrics are scraped by Prometheus (ServiceMonitor), and a
# PrometheusRule turns them into alerts that Alertmanager delivers like any
# other alert. Quiet means clean only because a second rule fires when the
# scanner stops producing data.
#
# Scope is the platform-system namespaces only. Tenant namespaces are out of
# scope on purpose.

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


# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
  alerting  = var.enabled && var.alerts_enabled ? toset(["enabled"]) : toset([])

  # Namespace allowlist: the platform-system namespaces this engine creates.
  target_namespaces = distinct(concat([
    "platform",
    "ops",
    "ingress-controller",
    "cert-manager",
    "argocd",
    "arc-system",
    "arc-runners",
    "arc-buildkitd",
    "vault",
    "vault-config-operator",
    "vault-secrets-operator",
    "zitadel",
    "monitoring",
    "longhorn-system",
    "metallb-system",
    "mail",
    var.namespace,
  ], var.extra_target_namespaces))

  tags = module.label.tags
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "security-scan"
  tags = {
    "app.kubernetes.io/component" = "security-scan"
  }
}


# ── Namespace ──────────────────────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "security-scan"
    })
  }
}


# ── Trivy-Operator ─────────────────────────────────────────────────────────

# CRDs come pre-rendered from the root (`operator_crds.tf`), because
# Helm never upgrades a chart's `crds/`; server-side apply keeps them
# matching the chart version.
resource "kubectl_manifest" "trivy_operator_crds" {
  for_each = { for doc in var.trivy_operator_crds : yamldecode(doc).metadata.name => doc }

  yaml_body         = each.value
  server_side_apply = true
  # Keep CRDs when this module is disabled or the resource is removed:
  # deleting a CRD deletes every object of that kind cluster-wide.
  # Retiring them is a deliberate manual step.
  apply_only = true
  # The chart created them client-side on first install; take over the
  # fields it set.
  force_conflicts = true
}

resource "helm_release" "trivy_operator" {
  for_each = local.instances

  depends_on = [
    kubernetes_namespace_v1.this,
    kubectl_manifest.trivy_operator_crds,
  ]

  name       = "trivy-operator"
  repository = "https://aquasecurity.github.io/helm-charts/"
  chart      = "trivy-operator"
  # Helm keeps one Secret per revision; each holds the full rendered
  # manifest, so unbounded history slowly fills etcd.
  max_history      = 3
  version          = var.trivy_operator_chart_version
  namespace        = kubernetes_namespace_v1.this["enabled"].metadata[0].name
  create_namespace = false

  values = [yamlencode({
    targetNamespaces = join(",", local.target_namespaces)

    operator = {
      vulnerabilityScannerEnabled                  = true
      vulnerabilityScannerScanOnlyCurrentRevisions = true
      # Nothing consumes the other report kinds; each one is more etcd
      # objects and more scan Jobs.
      configAuditScannerEnabled     = false
      rbacAssessmentScannerEnabled  = false
      infraAssessmentScannerEnabled = false
      clusterComplianceEnabled      = false
      exposedSecretScannerEnabled   = false
      # SBOM reports are the largest objects the operator writes (a full
      # package list per image) and nothing reads them.
      sbomGenerationEnabled = false
      # The chart default (10) starts ten scans at once; with a shared
      # trivy cache they then fail on its lock, and they pile onto one node.
      scanJobsConcurrentLimit = var.scan_jobs_concurrent_limit
      scanJobTimeout          = var.scan_job_timeout
      # The chart default grants the operator get/create/update on Secrets
      # in every namespace (to pull private images). The scan allowlist does
      # not narrow RBAC, so that would expose tenant credentials. Private
      # images are then reported as scan failures instead.
      accessGlobalSecretsAndServiceAccount = false
      # Built-in trivy server: one StatefulSet holds the vulnerability DB on
      # a PVC and scan Jobs run as thin clients against it. In Standalone
      # mode every container of a scan Pod opens the same local cache and
      # multi-container workloads fail on its lock.
      builtInTrivyServer = var.builtin_trivy_server
    }

    trivy = {
      severity = var.severity
      # Findings without a fixed version cannot be acted on and never go
      # away; keeping them makes every alert permanent noise.
      ignoreUnfixed = var.ignore_unfixed
      slow          = true # lower memory per scan at some CPU cost
      resources     = var.scan_job_resources

      # Server DB storage (built-in server only). Empty class = cluster
      # default; with a node-local class keep `node_selector` set so the
      # server stays next to its volume.
      storageClassEnabled = var.builtin_trivy_server
      storageClassName    = var.trivy_server_storage_class
      storageSize         = var.trivy_server_storage_size
      server = {
        resources = var.trivy_server_resources
      }
    }

    resources = var.operator_resources

    serviceMonitor = {
      enabled = var.service_monitor_enabled
    }

    # Operator and scan jobs on the same nodes: the jobs pull every
    # scanned image and the vulnerability DB, so place them where egress
    # is fastest.
    nodeSelector = var.node_selector
    trivyOperator = {
      scanJobNodeSelector = var.node_selector
    }
  })]
}


# ── Alerts ─────────────────────────────────────────────────────────────────
#
# Requires the ServiceMonitor (metrics in Prometheus). One alert per image
# with fixable findings at the alert severity, grouped by Alertmanager into
# one notification; plus a dead-man rule so "no alert" can't also mean "the
# scanner is broken". `alert_labels` carries the routing labels the
# platform's Alertmanager matches on.

resource "kubectl_manifest" "alerts" {
  for_each = local.alerting

  depends_on = [helm_release.trivy_operator]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "security-scan"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels = merge(local.tags, {
        # kube-prometheus-stack selects rules by this label.
        release = "kube-prometheus-stack"
      })
    }
    spec = {
      groups = [{
        name = "security-scan"
        rules = [
          {
            alert = "ImageVulnerabilities"
            expr  = "sum by (image_registry, image_repository, image_tag) (trivy_image_vulnerabilities{severity=~\"${join("|", var.alert_severities)}\"}) > 0"
            for   = "15m"
            # Series carry the scanned workload's namespace; pin the alert to
            # the scanner's namespace so it routes in one place.
            labels = merge(var.alert_labels, {
              severity  = "warning"
              namespace = var.namespace
            })
            annotations = {
              summary     = "{{ $labels.image_repository }}:{{ $labels.image_tag }} has {{ $value }} fixable ${join("/", var.alert_severities)} vulnerabilities"
              description = "Details: kubectl get vulnerabilityreports -A | grep '{{ $labels.image_repository }}'. Bump the image (or its chart) to a version with the fixes."
            }
          },
          {
            alert = "SecurityScanNoData"
            expr  = "absent(trivy_image_vulnerabilities)"
            for   = "6h"
            labels = merge(var.alert_labels, {
              severity  = "warning"
              namespace = var.namespace
            })
            annotations = {
              summary     = "trivy-operator exports no vulnerability metrics"
              description = "No trivy_image_vulnerabilities series for 6h: the operator is down, not scraped, or scans keep failing. Until fixed, the absence of ImageVulnerabilities alerts means nothing."
            }
          },
        ]
      }]
    }
  })
}


# ── Grafana dashboard ──────────────────────────────────────────────────────
#
# One table of fixable findings per image, picked up by the Grafana
# dashboard sidecar (label `grafana_dashboard=1`).

resource "kubernetes_config_map_v1" "dashboard" {
  for_each = var.enabled && var.grafana_dashboard_enabled ? toset(["enabled"]) : toset([])

  metadata {
    name      = "security-scan-dashboard"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(local.tags, { grafana_dashboard = "1" })
  }

  data = {
    "security-scan.json" = jsonencode({
      title         = "Security scan"
      uid           = "security-scan"
      schemaVersion = 39
      refresh       = "15m"
      time          = { from = "now-6h", to = "now" }
      panels = [{
        type       = "table"
        title      = "Fixable vulnerabilities by image"
        gridPos    = { x = 0, y = 0, w = 24, h = 20 }
        datasource = { type = "prometheus", uid = "prometheus" }
        targets = [{
          refId   = "A"
          expr    = "sum by (namespace, image_repository, image_tag, severity) (trivy_image_vulnerabilities) > 0"
          instant = true
          format  = "table"
        }]
        transformations = [
          { id = "organize", options = { excludeByName = { Time = true } } },
          { id = "sortBy", options = { sort = [{ field = "Value", desc = true }] } },
        ]
      }]
    })
  }
}
