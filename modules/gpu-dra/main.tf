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
        # See every GPU process to attribute VRAM to its pod: host PID namespace
        # for the processes, SYS_PTRACE to read a non-root process's DRM fdinfo.
        host_pid = true
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
              # Read other pods' /proc/<pid>/fdinfo (DRM VRAM per process).
              add = ["SYS_PTRACE"]
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
      selector = { matchLabels = local.labels }
      # Device names (PCI addresses) repeat across identical machines.
      podMetricsEndpoints = [{
        port        = "metrics"
        relabelings = [{ sourceLabels = ["__meta_kubernetes_pod_node_name"], targetLabel = "node" }]
      }]
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
            expr        = "dri_vram_used_bytes > dri_vram_allocated_bytes + (dri_vram_total_bytes - dri_vram_published_bytes) and dri_vram_allocated_bytes > 0"
            for         = "10m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.node }} {{ $labels.device }}: workloads use more VRAM than they claimed" }
          },
          {
            # Per-pod version of the above: names the pod that uses more than it
            # claimed (DRA accounts, the kernel does not cap), e.g. one that
            # sized its claim for weights only. 10 % over its claim.
            alert       = "DRIClaimVRAMOverClaim"
            expr        = "dri_claim_vram_used_bytes > dri_claim_vram_bytes * 1.1 and dri_claim_vram_bytes > 0"
            for         = "5m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.namespace }}/{{ $labels.pod }} on {{ $labels.device }}: uses more VRAM than it claimed" }
          },
          {
            alert       = "DRIVRAMNearlyFull"
            expr        = "dri_vram_used_bytes / dri_vram_total_bytes > 0.95"
            for         = "10m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.node }} {{ $labels.device }}: VRAM over 95 % used" }
          },
          {
            # Each Vulkan process keeps a few hundred MiB in GTT normally; with
            # VRAM full, buffers move there and the GPU slows down several times.
            alert       = "DRIVRAMEvictedToRAM"
            expr        = "dri_gtt_used_bytes > 1073741824 and dri_vram_used_bytes / dri_vram_total_bytes > 0.9"
            for         = "5m"
            labels      = { severity = "warning" }
            annotations = { summary = "{{ $labels.node }} {{ $labels.device }}: VRAM is full and buffers spill into system RAM" }
          },
        ]
      }]
    }
  })
}

# The plugin's ServiceAccount may write only the ResourceSlices of the node
# its pod runs on (node name from the pod-bound ServiceAccount token).
resource "kubectl_manifest" "slice_policy" {
  for_each = local.set
  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = "dra-driver-dri-resourceslices" }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["resource.k8s.io"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE", "DELETE"]
          resources   = ["resourceslices"]
        }]
      }
      matchConditions = [{
        name       = "isPlugin"
        expression = "request.userInfo.username == \"system:serviceaccount:${var.namespace}:dra-driver-dri\""
      }]
      variables = [
        { name = "userNodeName", expression = "request.userInfo.extra[?'authentication.kubernetes.io/node-name'][0].orValue('')" },
        { name = "objectNodeName", expression = "(request.operation == \"DELETE\" ? oldObject : object).spec.?nodeName.orValue(\"\")" },
      ]
      validations = [
        { expression = "variables.userNodeName != \"\"", message = "no node in the ServiceAccount token; the plugin must run in a pod on a node" },
        {
          expression        = "variables.userNodeName == variables.objectNodeName"
          messageExpression = "\"the plugin on node '\" + variables.userNodeName + \"' may not modify ResourceSlices of node '\" + variables.objectNodeName + \"'\""
        },
      ]
    }
  })
}

resource "kubectl_manifest" "slice_policy_binding" {
  for_each   = local.set
  depends_on = [kubectl_manifest.slice_policy]
  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = "dra-driver-dri-resourceslices" }
    spec = {
      policyName        = "dra-driver-dri-resourceslices"
      validationActions = ["Deny"]
    }
  })
}

# Dashboard from the driver repo (deploy/examples/grafana-dashboard.json),
# loaded by the Grafana sidecar of kube-prometheus-stack.
resource "kubernetes_config_map_v1" "dashboard" {
  for_each = local.set
  metadata {
    name      = "dra-driver-dri-dashboard"
    namespace = var.namespace
    labels    = merge(local.labels, { grafana_dashboard = "1" })
  }
  data = {
    "dra-driver-dri.json" = file("${path.module}/dashboard.json")
  }
}
