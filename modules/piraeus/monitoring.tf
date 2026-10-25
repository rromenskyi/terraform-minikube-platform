# Metrics and alerts: the LINSTOR controller (cluster view: nodes, storage
# pools) and drbd-reactor on every Satellite (the DRBD view from each node:
# connections, disks, quorum, suspended I/O).

locals {
  monitoring_set = var.enabled && var.monitoring ? toset(["enabled"]) : toset([])
  job_controller = "${var.namespace}/linstor-controller"
  job_satellite  = "${var.namespace}/linstor-satellite"
}

resource "kubectl_manifest" "pod_monitor_controller" {
  for_each   = local.monitoring_set
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "linstor-controller"
      namespace = var.namespace
      labels    = var.prometheus_selector_labels
    }
    spec = {
      selector            = { matchLabels = { "app.kubernetes.io/component" = "linstor-controller" } }
      podMetricsEndpoints = [{ port = "api", path = "/metrics", interval = "60s" }]
    }
  })
}

resource "kubectl_manifest" "pod_monitor_satellite" {
  for_each   = local.monitoring_set
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "linstor-satellite"
      namespace = var.namespace
      labels    = var.prometheus_selector_labels
    }
    spec = {
      selector = { matchLabels = { "app.kubernetes.io/component" = "linstor-satellite" } }
      podMetricsEndpoints = [{
        port        = "prometheus"
        relabelings = [{ sourceLabels = ["__meta_kubernetes_pod_node_name"], targetLabel = "node" }]
      }]
    }
  })
}

resource "kubectl_manifest" "rules" {
  for_each   = local.monitoring_set
  depends_on = [helm_release.operator]
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata = {
      name      = "piraeus"
      namespace = var.namespace
      labels    = var.prometheus_selector_labels
    }
    spec = {
      groups = [
        {
          name = "linstor"
          rules = [
            {
              alert       = "LinstorControllerDown"
              expr        = "absent(up{job=\"${local.job_controller}\"} == 1)"
              for         = "10m"
              labels      = { severity = "critical" }
              annotations = { summary = "LINSTOR controller is down: no new volumes, no attach/detach" }
            },
            {
              # LINSTOR node states: 2 = ONLINE. Only for nodes still
              # registered in Kubernetes: a node removed on purpose (e.g. a
              # powered-off autoscaled node) keeps its LINSTOR node under
              # deletionPolicy Retain, offline until it registers again.
              alert       = "LinstorSatelliteNotOnline"
              expr        = "linstor_node_state{nodetype=\"SATELLITE\"} != 2 and on (node) kube_node_info"
              for         = "5m"
              labels      = { severity = "critical" }
              annotations = { summary = "LINSTOR satellite {{ $labels.node }} is not online" }
            },
            {
              alert       = "LinstorStoragePoolError"
              expr        = "linstor_storage_pool_error_count > 0"
              for         = "10m"
              labels      = { severity = "critical" }
              annotations = { summary = "LINSTOR storage pool {{ $labels.storage_pool }} on {{ $labels.node }} reports errors" }
            },
            {
              alert       = "LinstorStoragePoolSpaceLow"
              expr        = "linstor_storage_pool_capacity_free_bytes / linstor_storage_pool_capacity_total_bytes < 0.15 and linstor_storage_pool_capacity_total_bytes > 0"
              for         = "30m"
              labels      = { severity = "warning" }
              annotations = { summary = "LINSTOR storage pool {{ $labels.storage_pool }} on {{ $labels.node }} is under 15 % free" }
            },
          ]
        },
        {
          name = "drbd"
          rules = [
            {
              alert       = "DrbdReactorDown"
              expr        = "up{job=\"${local.job_satellite}\"} == 0"
              for         = "10m"
              labels      = { severity = "warning" }
              annotations = { summary = "{{ $labels.node }}: drbd-reactor metrics unreachable (DRBD alerts for this node are blind)" }
            },
            {
              alert       = "DrbdConnectionLost"
              expr        = "drbd_connection_state{drbd_connection_state=\"Connected\"} == 0"
              for         = "5m"
              labels      = { severity = "critical" }
              annotations = { summary = "{{ $labels.node }}: DRBD {{ $labels.name }} not connected to {{ $labels.conn_name }}" }
            },
            {
              alert       = "DrbdBackingDiskLost"
              expr        = "drbd_device_unintentionaldiskless == 1"
              for         = "1m"
              labels      = { severity = "critical" }
              annotations = { summary = "{{ $labels.node }}: DRBD {{ $labels.name }} lost its backing disk (I/O goes to a peer or fails)" }
            },
            {
              alert       = "DrbdIOSuspended"
              expr        = "drbd_resource_suspended == 1"
              for         = "1m"
              labels      = { severity = "critical" }
              annotations = { summary = "{{ $labels.node }}: DRBD {{ $labels.name }} has I/O suspended" }
            },
            {
              alert       = "DrbdQuorumLost"
              expr        = "drbd_device_quorum == 0"
              for         = "1m"
              labels      = { severity = "critical" }
              annotations = { summary = "{{ $labels.node }}: DRBD {{ $labels.name }} lost quorum" }
            },
            {
              alert       = "DrbdOutOfSync"
              expr        = "drbd_peerdevice_outofsync_bytes > 0"
              for         = "30m"
              labels      = { severity = "warning" }
              annotations = { summary = "{{ $labels.node }}: DRBD {{ $labels.name }} out of sync with {{ $labels.conn_name }} for 30 min" }
            },
          ]
        },
      ]
    }
  })
}
