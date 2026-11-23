# NVR: Frigate records cameras, detects objects and serves the UI.
#
# The configuration is an object from the caller (`frigate_config`),
# rendered to config.yml. Camera credentials never appear in it: they are
# `{FRIGATE_*}` placeholders, filled from a Vault secret (VSO) passed to
# the container as environment variables.
#
# config.yml lives in a ConfigMap and is copied onto the writable /config
# volume by an init container on every start, so the declared
# configuration always wins (edits saved from Frigate's UI last until the
# next restart). /config also holds Frigate's database; recordings go to
# their own volume at /media/frigate.
#
# The Service exposes port 5000, Frigate's API/UI without its own login:
# put an authenticating gate in front of it (e.g. `auth: zitadel`) and
# never route it unauthenticated.

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

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])
  tags      = module.label.tags
  labels    = { "app.kubernetes.io/name" = "frigate" }

  config = merge(
    { mqtt = { enabled = false } },
    var.frigate_config,
    { database = { path = "/config/frigate.db" } },
  )
  config_yaml = yamlencode(local.config)

  secret_name = "frigate-env"

  # Quantities in MiB / millicores for the plan-time checks (the variables'
  # validations guarantee these suffixes).
  mib = {
    for k, v in {
      shm     = var.shm_size
      cache   = var.cache_size
      limit   = var.resources.limits.memory
      request = var.resources.requests.memory
      quota   = var.quota.memory
    } : k => tonumber(regex("^([0-9]+)", v)[0]) * (endswith(v, "Gi") ? 1024 : 1)
  }
  millicores = {
    for k, v in {
      limit   = var.resources.limits.cpu
      request = var.resources.requests.cpu
      quota   = var.quota.cpu
    } : k => endswith(v, "m") ? tonumber(trimsuffix(v, "m")) : tonumber(v) * 1000
  }
  # The init container's limits (see the Deployment). Kubernetes charges a
  # pod max(init container, app containers) per resource, not the sum.
  init_limit = { mib = 64, millicores = 200 }
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "frigate"
  tags = {
    "app.kubernetes.io/component" = "nvr"
  }
}

resource "terraform_data" "checks" {
  for_each = local.instances

  lifecycle {
    precondition {
      condition     = var.storage_class != ""
      error_message = "var.storage_class is required — use a replicated class so the NVR can restart on another node with its recordings."
    }
    precondition {
      condition     = local.mib.shm + local.mib.cache < local.mib.limit
      error_message = "shm_size + cache_size (${local.mib.shm + local.mib.cache} MiB) must stay below resources.limits.memory (${local.mib.limit} MiB): both are memory-backed and count against the limit."
    }
    precondition {
      condition = alltrue([
        max(local.mib.limit, local.init_limit.mib) <= local.mib.quota,
        max(local.millicores.limit, local.init_limit.millicores) <= local.millicores.quota,
        local.mib.request <= local.mib.limit,
        local.millicores.request <= local.millicores.limit,
      ])
      error_message = "resources.requests must not exceed resources.limits, and quota must cover resources.limits (and the init container's 64Mi/200m); otherwise the pod is rejected by the ResourceQuota."
    }
    precondition {
      condition     = length(try(keys(var.frigate_config.cameras), [])) > 0
      error_message = "var.frigate_config.cameras is empty — an NVR without cameras is a misconfiguration."
    }
  }
}

# ── Namespace (PSA baseline) ───────────────────────────────────────────────

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(local.tags, {
      "app.kubernetes.io/managed-by"       = "terraform"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
    })
  }
}

# A ceiling for the namespace (AGENT.md): Frigate and its init container
# (Recreate: no rollout overlap). Containers without resources get the
# LimitRange defaults.
resource "kubernetes_resource_quota_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "nvr"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
  spec {
    hard = {
      pods              = "4"
      "requests.cpu"    = var.quota.cpu
      "limits.cpu"      = var.quota.cpu
      "requests.memory" = var.quota.memory
      "limits.memory"   = var.quota.memory
    }
  }
}

resource "kubernetes_limit_range_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "nvr"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
  spec {
    limit {
      type            = "Container"
      default         = { cpu = "500m", memory = "512Mi" }
      default_request = { cpu = "50m", memory = "64Mi" }
    }
  }
}

# ── Camera credentials from Vault (VSO) ────────────────────────────────────

# VSO impersonates this SA in the namespace of the VaultStaticSecret (same
# pattern as modules/samba).
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = local.instances

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(local.tags, { "app.kubernetes.io/managed-by" = "terraform" })
  }
}

resource "kubectl_manifest" "vault_auth" {
  for_each = var.enabled && var.vault_auth_role != "" ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "vault-nvr"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = merge(local.tags, { "app.kubernetes.io/managed-by" = "terraform" })
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role                   = var.vault_auth_role
        serviceAccount         = kubernetes_service_account_v1.vso_proxy["enabled"].metadata[0].name
        tokenExpirationSeconds = 600
      }
    }
  })
}

# Every key at `vault_path` becomes an environment variable (FRIGATE_*).
# A change restarts Frigate.
resource "kubectl_manifest" "env_vault" {
  for_each = local.instances

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_service_account_v1.vso_proxy,
    kubectl_manifest.vault_auth,
  ]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = local.secret_name
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = merge(local.tags, { "app.kubernetes.io/managed-by" = "terraform" })
    }
    spec = {
      vaultAuthRef = var.vault_auth_role != "" ? "vault-nvr" : ""
      mount        = "secret"
      type         = "kv-v2"
      path         = var.vault_path
      destination = {
        name           = local.secret_name
        create         = true
        transformation = { excludeRaw = true }
      }
      rolloutRestartTargets = [{ kind = "Deployment", name = "frigate" }]
      refreshAfter          = "60s"
    }
  })
}

# ── Configuration ───────────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "config" {
  for_each = local.instances

  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }

  data = {
    "config.yml" = local.config_yaml
  }
}

# ── Volumes ─────────────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "config" {
  for_each = local.instances

  metadata {
    name      = "frigate-config"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = { storage = var.config_size }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "media" {
  for_each = local.instances

  metadata {
    name      = "frigate-media"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.storage_class
    resources {
      requests = { storage = var.recordings_size }
    }
  }
  wait_until_bound = false
}

# ── Frigate ─────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  for_each = local.instances

  depends_on = [terraform_data.checks, kubectl_manifest.env_vault]

  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(local.tags, local.labels)
  }

  # The Secret appears only after VSO's first sync.
  wait_for_rollout = false

  spec {
    replicas = 1
    # Both volumes are ReadWriteOnce: the old pod must let go first.
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = merge(local.tags, local.labels)
        annotations = {
          "checksum/config" = sha256(local.config_yaml)
        }
      }
      spec {
        node_selector = var.node_selector

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        # The declared config.yml replaces whatever is on /config.
        init_container {
          name    = "config"
          image   = var.image
          command = ["sh", "-c", "cp /etc/frigate/config.yml /config/config.yml"]
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "config-file"
            mount_path = "/etc/frigate"
            read_only  = true
          }
          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "200m", memory = "64Mi" }
          }
        }

        container {
          name  = "frigate"
          image = var.image

          env_from {
            secret_ref {
              name = local.secret_name
            }
          }

          port {
            name           = "http"
            container_port = 5000
          }
          port {
            name           = "rtsp"
            container_port = 8554
          }
          port {
            name           = "webrtc-tcp"
            container_port = 8555
            protocol       = "TCP"
          }
          port {
            name           = "webrtc-udp"
            container_port = 8555
            protocol       = "UDP"
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          startup_probe {
            http_get {
              path = "/api/version"
              port = "http"
            }
            period_seconds    = 10
            failure_threshold = 30
          }
          readiness_probe {
            http_get {
              path = "/api/version"
              port = "http"
            }
            period_seconds    = 10
            timeout_seconds   = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/api/version"
              port = "http"
            }
            period_seconds    = 30
            timeout_seconds   = 5
            failure_threshold = 5
          }

          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "media"
            mount_path = "/media/frigate"
          }
          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/tmp/cache"
          }
        }

        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.config["enabled"].metadata[0].name
          }
        }
        volume {
          name = "media"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.media["enabled"].metadata[0].name
          }
        }
        volume {
          name = "config-file"
          config_map {
            name = kubernetes_config_map_v1.config["enabled"].metadata[0].name
          }
        }
        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = var.shm_size
          }
        }
        volume {
          name = "cache"
          empty_dir {
            medium     = "Memory"
            size_limit = var.cache_size
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "frigate"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(local.tags, local.labels)
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 5000
      target_port = "http"
    }
    port {
      name        = "rtsp"
      port        = 8554
      target_port = "rtsp"
    }
    port {
      name        = "webrtc-tcp"
      port        = 8555
      target_port = "webrtc-tcp"
      protocol    = "TCP"
    }
    port {
      name        = "webrtc-udp"
      port        = 8555
      target_port = "webrtc-udp"
      protocol    = "UDP"
    }
  }
}

# Port 5000 has no login: only pods in the ingress controller's namespace
# (which applies the gate) and Prometheus's namespace may reach the pod.
# Needs a CNI or controller that enforces NetworkPolicy (k3s's built-in
# one does unless started with --disable-network-policy). Cameras are reached outbound and
# are not affected.
resource "kubernetes_network_policy_v1" "ingress" {
  for_each = var.enabled && length(var.ingress_from_namespaces) > 0 ? toset(["enabled"]) : toset([])

  metadata {
    name      = "frigate-ingress"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = local.tags
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      dynamic "from" {
        for_each = var.ingress_from_namespaces
        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.value }
          }
        }
      }
    }
  }
}

# ── Monitoring ──────────────────────────────────────────────────────────────

resource "kubectl_manifest" "service_monitor" {
  for_each   = local.instances
  depends_on = [kubernetes_service_v1.this]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "frigate"
      namespace = var.namespace
      labels    = merge(local.labels, { release = "kube-prometheus-stack" })
    }
    spec = {
      selector  = { matchLabels = local.labels }
      endpoints = [{ port = "http", path = "/api/metrics", interval = "60s" }]
    }
  })
}

resource "kubectl_manifest" "rules" {
  for_each   = local.instances
  depends_on = [kubernetes_namespace_v1.this]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "frigate"
      namespace = var.namespace
      labels    = merge(local.labels, { release = "kube-prometheus-stack" })
    }
    spec = {
      groups = [{
        name = "nvr"
        rules = [
          {
            alert       = "FrigateDown"
            expr        = "absent(up{namespace=\"${var.namespace}\",service=\"frigate\"} == 1)"
            for         = "15m"
            labels      = { severity = "warning" }
            annotations = { summary = "Frigate in ${var.namespace} is not answering its metrics endpoint: cameras are not being recorded" }
          },
          {
            alert = "FrigateRecordingsVolumeFull"
            expr = join("", [
              "kubelet_volume_stats_used_bytes{namespace=\"${var.namespace}\",persistentvolumeclaim=\"frigate-media\"}",
              " / kubelet_volume_stats_capacity_bytes{namespace=\"${var.namespace}\",persistentvolumeclaim=\"frigate-media\"}",
              " > ${var.volume_full_threshold}",
            ])
            for         = "30m"
            labels      = { severity = "warning" }
            annotations = { summary = "Frigate's recordings volume is over ${floor(var.volume_full_threshold * 100)}% full: shorten retention or grow the volume" }
          },
        ]
      }]
    }
  })
}
