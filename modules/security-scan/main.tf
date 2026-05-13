# Continuous CVE scanning of platform-system container images.
#
# Two-layer setup. The bottom layer is upstream `trivy-operator` (Aqua
# Security, https://github.com/aquasecurity/trivy-operator) — a
# Kubernetes operator that watches Pods cluster-wide, dispatches a
# trivy scan per unique image, and writes the result back as a
# `VulnerabilityReport` CRD next to the workload it covers. Configured
# here to scan only the platform-system namespaces (allowlist below).
# The DB cache that trivy needs (~700 MB) lives on a hostPath PV pinned
# to the operator's stateful node so re-creates of the operator pod
# don't re-pull the DB each time.
#
# The top layer is a weekly `CronJob` that collects every active
# VulnerabilityReport, formats the high/critical findings into a
# single `inventory/cve-report.md`, opens a PR against the platform
# repo if the report changed since last run, and silently exits
# otherwise. The PR is the audit trail: an operator scrolling git log
# of `inventory/cve-report.md` sees exactly when each new vulnerability
# entered the platform and when it left. Authentication uses a
# vault-backed PAT (`secret/data/platform/github-deploy-tokens/security-scan`).
#
# Scope is intentionally tight in v0 — only platform-owned namespaces
# (vault, zitadel, postgres, redis, etc.) are scanned. Tenant project
# namespaces (matching `var.namespace_prefix`-* on the root stack) are
# excluded; v1 will extend the allowlist + handle the leak surface
# around tenant naming in the public report.

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

  # Namespace allowlist. Static, hand-curated — this is the
  # public-repo "what we scan" surface. Tenant namespaces
  # (`var.namespace_prefix`-*) intentionally excluded in v0.
  target_namespaces = [
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
    "security-scan",
  ]

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


# ── Trivy-Operator: hostPath PV for vuln DB cache ──────────────────────────
#
# Trivy's vulnerability DB is ~700 MB. Without persistence the operator
# pod re-downloads on every restart — slow + wasteful. hostPath PV
# pinned to the operator's stateful tier node keeps the cache warm
# across pod recreates. Single replica is fine — trivy-operator is
# leader-elected internally and the upstream chart deploys one replica
# by default.

resource "kubernetes_persistent_volume_v1" "trivy_cache" {
  for_each = local.instances

  metadata {
    name = "platform-trivy-cache"
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "trivy-cache"
    })
  }

  spec {
    capacity = {
      storage = var.trivy_cache_size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "manual"
    volume_mode                      = "Filesystem"

    persistent_volume_source {
      host_path {
        path = "${var.host_volume_path}/trivy-cache"
        type = "DirectoryOrCreate"
      }
    }

    # Pin to the stateful tier node so the hostPath dir is
    # always reachable. Without this affinity the PV could
    # bind on any node, then Pod re-schedules elsewhere and
    # the volume's hostPath dir doesn't exist there.
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [var.cache_node_hostname]
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "trivy_cache" {
  for_each = local.instances

  metadata {
    name      = "trivy-cache"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    volume_name        = kubernetes_persistent_volume_v1.trivy_cache["enabled"].metadata[0].name

    resources {
      requests = {
        storage = var.trivy_cache_size
      }
    }
  }
}


# ── Trivy-Operator: Helm release ───────────────────────────────────────────

resource "helm_release" "trivy_operator" {
  for_each = local.instances

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_persistent_volume_claim_v1.trivy_cache,
  ]

  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts/"
  chart            = "trivy-operator"
  version          = var.trivy_operator_chart_version
  namespace        = kubernetes_namespace_v1.this["enabled"].metadata[0].name
  create_namespace = false

  values = [yamlencode({
    # Scan-target gating. `targetNamespaces` filters which Pods get
    # scanned to the platform-system allowlist. Empty would mean
    # "every namespace" — explicitly NOT what we want in v0.
    targetNamespaces = join(",", local.target_namespaces)

    # Severity floor. LOW + MEDIUM produce noise without action;
    # operator only wants to see what's actually exploitable.
    operator = {
      vulnerabilityScannerEnabled                  = true
      configAuditScannerEnabled                    = true
      rbacAssessmentScannerEnabled                 = false
      infraAssessmentScannerEnabled                = false
      clusterComplianceEnabled                     = false
      exposedSecretScannerEnabled                  = false
      vulnerabilityScannerScanOnlyCurrentRevisions = true
      scanJobTimeout                               = "5m"
    }

    trivy = {
      severity      = "HIGH,CRITICAL"
      ignoreUnfixed = false
      slow          = true # slow-mode keeps memory < 1 GiB on big scan jobs

      # Persistent cache mount — bound to the hostPath PVC above.
      # Without this trivy re-downloads the ~700 MB vuln DB on
      # every operator-pod restart.
      storageClassEnabled = false
      storageClassName    = ""
      storageSize         = ""

      # Resource sizing for scan Jobs trivy-operator spawns. These
      # are short-lived per-image scans (tens of seconds each), but
      # multiple can run in parallel — keep limits modest so a scan
      # storm doesn't starve real workloads.
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }

    # ServiceMonitor for Prometheus scrape — reuses the platform's
    # kube-prometheus-stack. Adds a `trivy_image_vulnerabilities`
    # gauge series Grafana can dashboard off.
    serviceMonitor = {
      enabled = var.service_monitor_enabled
    }
  })]
}


# ── Snapshot CronJob: collect VulnerabilityReports → commit to repo ────────
#
# Every Sunday 04:00 UTC (configurable). Pod sequence:
#   1. initContainer `collect`: kubectl get vulnerabilityreports -A
#      → format markdown table of HIGH/CRITICAL → write /work/cve-report.md
#   2. main container `commit-pr`: clone repo via PAT, diff
#      `inventory/cve-report.md`, if changed open a PR via curl + GitHub
#      API. If unchanged, exit 0 silently.

resource "kubernetes_service_account_v1" "snapshot" {
  for_each = local.instances

  metadata {
    name      = "security-scan-snapshot"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
}

# Read-only on VulnerabilityReports cluster-wide. The CronJob never
# writes back — only reads what trivy-operator emitted, formats it,
# and commits the result outside the cluster.
resource "kubernetes_cluster_role_v1" "snapshot" {
  for_each = local.instances

  metadata {
    name   = "security-scan-snapshot-read"
    labels = local.tags
  }

  rule {
    api_groups = ["aquasecurity.github.io"]
    resources  = ["vulnerabilityreports", "configauditreports"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "snapshot" {
  for_each = local.instances

  metadata {
    name   = "security-scan-snapshot-read"
    labels = local.tags
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.snapshot["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.snapshot["enabled"].metadata[0].name
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
  }
}

# VSO consuming-namespace SA — VSO impersonates this SA when
# authenticating against Vault's k8s auth method. Same pattern as
# `modules/project` and `modules/github-runners`.
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = local.instances

  depends_on = [kubernetes_namespace_v1.this]

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
}

# Vault-mode PAT for opening PRs. Operator places the value at
# `secret/data/platform/github-deploy-tokens/security-scan` (one key:
# `github_token`); VSO syncs into `security-scan-github-pat` Secret in
# this namespace; the CronJob mounts it as an env var.
resource "kubectl_manifest" "github_pat_vault" {
  for_each = local.instances

  depends_on = [kubernetes_service_account_v1.vso_proxy]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "security-scan-github-pat"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = local.tags
    }
    spec = {
      vaultAuthRef = ""
      mount        = "secret"
      type         = "kv-v2"
      path         = "platform/github-deploy-tokens/security-scan"
      destination = {
        name   = "security-scan-github-pat"
        create = true
      }
      refreshAfter = "30s"
    }
  })
}

# ConfigMap carrying the two scripts the CronJob runs. defaultMode
# 0755 in the volume mount so they're executable straight from the
# mount.
resource "kubernetes_config_map_v1" "scripts" {
  for_each = local.instances

  metadata {
    name      = "security-scan-scripts"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    "collect.sh"   = file("${path.module}/scripts/collect.sh")
    "commit-pr.sh" = file("${path.module}/scripts/commit-pr.sh")
  }
}

resource "kubernetes_cron_job_v1" "snapshot" {
  for_each = local.instances

  depends_on = [
    helm_release.trivy_operator,
    kubernetes_cluster_role_binding_v1.snapshot,
    kubectl_manifest.github_pat_vault,
  ]

  metadata {
    name      = "security-scan-snapshot"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  spec {
    schedule                      = var.snapshot_schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 300

    job_template {
      metadata {
        labels = local.tags
      }
      spec {
        backoff_limit = 1
        template {
          metadata {
            labels = local.tags
          }
          spec {
            service_account_name = kubernetes_service_account_v1.snapshot["enabled"].metadata[0].name
            restart_policy       = "OnFailure"

            init_container {
              name    = "collect"
              image   = "bitnami/kubectl:latest"
              command = ["/scripts/collect.sh"]

              env {
                name  = "TARGET_NAMESPACES"
                value = join(" ", local.target_namespaces)
              }

              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            container {
              name    = "commit-pr"
              image   = "alpine/git:latest"
              command = ["/scripts/commit-pr.sh"]

              env {
                name = "GH_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "security-scan-github-pat"
                    key  = "github_token"
                  }
                }
              }
              env {
                name  = "GH_REPO"
                value = var.github_repo
              }
              env {
                name  = "BRANCH_PREFIX"
                value = var.branch_prefix
              }
              env {
                name  = "REPORT_PATH"
                value = "inventory/cve-report.md"
              }

              volume_mount {
                name       = "work"
                mount_path = "/work"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
            }

            volume {
              name = "work"
              empty_dir {}
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.scripts["enabled"].metadata[0].name
                default_mode = "0755"
              }
            }
          }
        }
      }
    }
  }
}
