# DRA driver for DRM render-node GPUs (ipsupport-llc/dra-driver-dri): a
# kubelet plugin per GPU node publishes each GPU with a consumable `vram`
# capacity; pods claim VRAM from the DeviceClass `var.driver_name`.

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
  set    = var.enabled ? toset(["enabled"]) : toset([])
  labels = { "app.kubernetes.io/name" = "dra-driver-dri" }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.set
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_service_account_v1" "this" {
  for_each = local.set
  metadata {
    name      = "dra-driver-dri"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "this" {
  for_each = local.set
  metadata {
    name = "dra-driver-dri"
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceclaims"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceclaims/status"]
    verbs      = ["update"]
  }
  rule {
    api_groups     = ["resource.k8s.io"]
    resources      = ["resourceclaims/driver"]
    verbs          = ["associated-node:update", "associated-node:patch"]
    resource_names = [var.driver_name]
  }
  rule {
    api_groups = ["resource.k8s.io"]
    resources  = ["resourceslices"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  for_each = local.set
  metadata {
    name = "dra-driver-dri"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this["enabled"].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_daemon_set_v1" "this" {
  for_each = local.set
  metadata {
    name      = "dra-driver-dri"
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    selector {
      match_labels = local.labels
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        service_account_name = kubernetes_service_account_v1.this["enabled"].metadata[0].name
        priority_class_name  = "system-node-critical"
        node_selector        = var.node_selector
        container {
          name  = "plugin"
          image = var.image
          env {
            name  = "DRIVER_NAME"
            value = var.driver_name
          }
          env {
            name  = "VRAM_RESERVE"
            value = var.vram_reserve
          }
          env {
            name  = "RESCAN_INTERVAL"
            value = var.rescan_interval
          }
          env {
            name = "NODE_NAME"
            value_from {
              field_ref {
                field_path = "spec.nodeName"
              }
            }
          }
          env {
            name = "POD_UID"
            value_from {
              field_ref {
                field_path = "metadata.uid"
              }
            }
          }
          port {
            name           = "metrics"
            container_port = 8080
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            period_seconds = 30
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "plugins-registry"
            mount_path = "/var/lib/kubelet/plugins_registry"
          }
          volume_mount {
            name       = "plugins"
            mount_path = "/var/lib/kubelet/plugins"
          }
          volume_mount {
            name       = "cdi"
            mount_path = "/var/run/cdi"
          }
          volume_mount {
            name       = "sys"
            mount_path = "/sys"
            read_only  = true
          }
        }
        volume {
          name = "plugins-registry"
          host_path {
            path = "/var/lib/kubelet/plugins_registry"
            type = "Directory"
          }
        }
        volume {
          name = "plugins"
          host_path {
            path = "/var/lib/kubelet/plugins"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "cdi"
          host_path {
            path = "/var/run/cdi"
            type = "DirectoryOrCreate"
          }
        }
        volume {
          name = "sys"
          host_path {
            path = "/sys"
            type = "Directory"
          }
        }
      }
    }
  }
}

resource "kubectl_manifest" "device_class" {
  for_each = local.set
  yaml_body = yamlencode({
    apiVersion = "resource.k8s.io/v1"
    kind       = "DeviceClass"
    metadata   = { name = var.driver_name }
    spec = {
      selectors = [{ cel = { expression = "device.driver == \"${var.driver_name}\"" } }]
    }
  })
}

resource "kubectl_manifest" "pod_monitor" {
  for_each   = local.set
  depends_on = [kubernetes_daemon_set_v1.this]
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "dra-driver-dri"
      namespace = var.namespace
      labels    = merge(local.labels, var.prometheus_selector_labels)
    }
    spec = {
      selector            = { matchLabels = local.labels }
      podMetricsEndpoints = [{ port = "metrics" }]
    }
  })
}

resource "kubectl_manifest" "rules" {
  for_each = local.set
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "dra-driver-dri"
      namespace = var.namespace
      labels    = merge(local.labels, var.prometheus_selector_labels)
    }
    spec = {
      groups = [{
        name = "dra-driver-dri"
        rules = [
          {
            alert  = "DRIPluginMissing"
            expr   = "absent(up{namespace=\"${var.namespace}\",pod=~\"dra-driver-dri-.*\"} == 1)"
            for    = "10m"
            labels = { severity = "warning" }
            annotations = {
              summary = "No dra-driver-dri plugin is running (GPU claims cannot be prepared)"
            }
          },
          {
            alert       = "DRIPrepareErrors"
            expr        = "increase(dri_prepare_errors_total[15m]) > 0"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.pod }}: GPU claims fail to prepare" }
          },
          {
            alert       = "DRIVRAMOverUse"
            expr        = "dri_vram_used_bytes > dri_vram_allocated_bytes and dri_vram_allocated_bytes > 0"
            for         = "10m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.device }}: workloads use more VRAM than they claimed" }
          },
          {
            alert       = "DRIVRAMNearlyFull"
            expr        = "dri_vram_used_bytes / dri_vram_total_bytes > 0.95"
            for         = "10m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.device }}: VRAM over 95 % used" }
          },
        ]
      }]
    }
  })
}
