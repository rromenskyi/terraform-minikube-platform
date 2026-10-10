# Disk health: SMART data of the nodes' physical drives, next to what
# writes to them.
#
# Upstream `smartctl_exporter` (prometheus-community) runs as a DaemonSet
# and exports each drive's SMART log: wear (`percentage_used`), bytes
# written, spare blocks, media errors, temperature. Prometheus scrapes it
# through the chart's ServiceMonitor; a relabel adds the node name.
#
# The dashboard puts wear next to the write rate (node_exporter), the
# write latency and the top writing namespaces (cAdvisor), so a wearing or
# slow drive points straight at its cause. The "days left" estimate needs
# no rated endurance: the drive's own counters give bytes written per
# percent of wear, divided by the recent write rate.

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
  }
}


# ── Locals ─────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  datasource = { type = "prometheus", uid = "prometheus" }

  # node_exporter series carry the node's IP, not its name. `%s` = a
  # node_exporter expression; the result gains a `node` label.
  with_node_name = "label_replace(%s, \"internal_ip\", \"$1\", \"instance\", \"(.*):[0-9]+\") * on (internal_ip) group_left (node) max by (internal_ip, node) (kube_node_info)"

  # Drives that report wear. Virtual disks export a few zero-valued
  # series and nothing else; `and on (...) <this>` keeps them out.
  wearing_drives = "max by (node, device) (smartctl_device_percentage_used)"

  # Block devices only; no device-mapper, loop or optical layers that
  # would count the same writes twice.
  disk_devices = "device!~\"dm-.*|loop.*|sr.*\""

  tags = module.label.tags
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "disk-health"
  tags = {
    "app.kubernetes.io/component" = "disk-health"
  }
}


# ── smartctl_exporter ──────────────────────────────────────────────────────

resource "helm_release" "smartctl_exporter" {
  for_each = local.instances

  name       = "smartctl-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-smartctl-exporter"
  # Helm keeps one Secret per revision; each holds the full rendered
  # manifest, so unbounded history slowly fills etcd.
  max_history = 3
  version     = var.chart_version
  namespace   = var.namespace

  values = [yamlencode({
    fullnameOverride = "smartctl-exporter"
    image = {
      repository = var.image_repository
      tag        = var.image_tag
    }
    # The chart runs the container privileged as root with the host's
    # /dev mounted: reading a drive's SMART log is a raw device ioctl.
    affinity  = var.affinity
    resources = var.resources
    serviceMonitor = {
      enabled = true
      relabelings = [{
        sourceLabels = ["__meta_kubernetes_pod_node_name"]
        targetLabel  = "node"
      }]
    }
  })]
}


# ── Grafana dashboard ──────────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "dashboard" {
  for_each = var.enabled && var.grafana_dashboard_enabled ? toset(["enabled"]) : toset([])

  metadata {
    name      = "disk-health-dashboard"
    namespace = var.namespace
    labels    = merge(local.tags, { grafana_dashboard = "1" })
  }

  data = {
    "disk-health.json" = jsonencode({
      title         = "Disk health"
      uid           = "disk-health"
      schemaVersion = 39
      refresh       = "5m"
      time          = { from = "now-7d", to = "now" }
      panels = [
        {
          type       = "table"
          title      = "Drives"
          gridPos    = { x = 0, y = 0, w = 24, h = 7 }
          datasource = local.datasource
          targets = [
            for t in [
              { id = "Model", expr = "max by (node, device, model_name) (smartctl_device)" },
              { id = "Wear", expr = "max by (node, device) (smartctl_device_percentage_used)" },
              { id = "DaysLeft", expr = "max by (node, device) ((100 - smartctl_device_percentage_used) * smartctl_device_bytes_written / (smartctl_device_percentage_used > 0) / (rate(smartctl_device_bytes_written[3d]) * 86400 > 0))" },
              { id = "Written", expr = "max by (node, device) (smartctl_device_bytes_written) / 1e12" },
              { id = "Spare", expr = "max by (node, device) (smartctl_device_available_spare)" },
              { id = "MediaErrors", expr = "max by (node, device) (smartctl_device_media_errors)" },
              { id = "Temp", expr = "max by (node, device) (smartctl_device_temperature{temperature_type=\"current\"})" },
              { id = "PowerOn", expr = "max by (node, device) (smartctl_device_power_on_seconds) / 86400" },
              ] : {
              refId   = t.id
              expr    = "${t.expr} and on (node, device) ${local.wearing_drives}"
              instant = true
              format  = "table"
            }
          ]
          transformations = [
            { id = "merge", options = {} },
            {
              id = "organize"
              options = {
                excludeByName = { Time = true, "Value #Model" = true }
                renameByName = {
                  node                 = "Node"
                  device               = "Device"
                  model_name           = "Model"
                  "Value #Wear"        = "Wear %"
                  "Value #DaysLeft"    = "Days left at 3d write rate"
                  "Value #Written"     = "Written TB"
                  "Value #Spare"       = "Spare %"
                  "Value #MediaErrors" = "Media errors"
                  "Value #Temp"        = "Temp °C"
                  "Value #PowerOn"     = "Power-on days"
                }
              }
            },
          ]
          fieldConfig = {
            defaults = { decimals = 0 }
            overrides = [
              {
                matcher    = { id = "byName", options = "Written TB" }
                properties = [{ id = "decimals", value = 1 }]
              },
              {
                matcher = { id = "byName", options = "Wear %" }
                properties = [
                  { id = "custom.cellOptions", value = { type = "color-background" } },
                  { id = "thresholds", value = { mode = "absolute", steps = [
                    { color = "green", value = null },
                    { color = "orange", value = 70 },
                    { color = "red", value = 90 },
                  ] } },
                ]
              },
              {
                matcher = { id = "byName", options = "Days left at 3d write rate" }
                properties = [
                  { id = "custom.cellOptions", value = { type = "color-background" } },
                  { id = "thresholds", value = { mode = "absolute", steps = [
                    { color = "red", value = null },
                    { color = "orange", value = 180 },
                    { color = "green", value = 365 },
                  ] } },
                ]
              },
            ]
          }
        },
        {
          type        = "timeseries"
          title       = "Wear (% of rated life used)"
          gridPos     = { x = 0, y = 7, w = 12, h = 8 }
          datasource  = local.datasource
          targets     = [{ refId = "A", expr = local.wearing_drives, legendFormat = "{{node}} {{device}}" }]
          fieldConfig = { defaults = { unit = "percent" } }
        },
        {
          type       = "timeseries"
          title      = "Written per day (drive's own counter)"
          gridPos    = { x = 12, y = 7, w = 12, h = 8 }
          datasource = local.datasource
          targets = [{
            refId        = "A"
            expr         = "max by (node, device) (rate(smartctl_device_bytes_written[1d])) * 86400"
            legendFormat = "{{node}} {{device}}"
          }]
          fieldConfig = { defaults = { unit = "decbytes" } }
        },
        {
          type       = "timeseries"
          title      = "Disk writes"
          gridPos    = { x = 0, y = 15, w = 12, h = 8 }
          datasource = local.datasource
          targets = [{
            refId        = "A"
            expr         = "sum by (node, device) (${format(local.with_node_name, "rate(node_disk_written_bytes_total{${local.disk_devices}}[$__rate_interval])")})"
            legendFormat = "{{node}} {{device}}"
          }]
          fieldConfig = { defaults = { unit = "Bps" } }
        },
        {
          # Average time a write spends queued and served. A drive that is
          # saturated or wearing shows it here first; etcd and databases
          # stall on fsync once this climbs into tens of milliseconds.
          type       = "timeseries"
          title      = "Write latency (average per write)"
          gridPos    = { x = 12, y = 15, w = 12, h = 8 }
          datasource = local.datasource
          targets = [{
            refId        = "A"
            expr         = "sum by (node, device) (${format(local.with_node_name, "rate(node_disk_write_time_seconds_total{${local.disk_devices}}[$__rate_interval])")}) / sum by (node, device) (${format(local.with_node_name, "rate(node_disk_writes_completed_total{${local.disk_devices}}[$__rate_interval])")})"
            legendFormat = "{{node}} {{device}}"
          }]
          fieldConfig = { defaults = { unit = "s" } }
        },
        {
          type       = "timeseries"
          title      = "Top writers (namespace per node)"
          gridPos    = { x = 0, y = 23, w = 12, h = 9 }
          datasource = local.datasource
          targets = [{
            refId        = "A"
            expr         = "topk(10, sum by (node, namespace) (rate(container_fs_writes_bytes_total{container!=\"\"}[$__rate_interval])))"
            legendFormat = "{{node}} {{namespace}}"
          }]
          fieldConfig = { defaults = { unit = "Bps" } }
        },
        {
          type       = "timeseries"
          title      = "Temperature"
          gridPos    = { x = 12, y = 23, w = 12, h = 9 }
          datasource = local.datasource
          targets = [{
            refId        = "A"
            expr         = "max by (node, device) (smartctl_device_temperature{temperature_type=\"current\"}) and on (node, device) ${local.wearing_drives}"
            legendFormat = "{{node}} {{device}}"
          }]
          fieldConfig = { defaults = { unit = "celsius" } }
        },
      ]
    })
  }
}
