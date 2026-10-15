# Grafana dashboard for an OpenWrt router scraped through
# `monitoring.external_targets` (external_scrape.tf) with
# prometheus-node-exporter-lua: active uplink, throughput, drops and errors
# per interface, CPU by mode (softirq is where a router saturates), memory,
# conntrack, temperature.
#
#   monitoring:
#     openwrt_dashboard: router   # the external_targets entry of the router
#
# The hardware NAT, uplink, backlog-drop and temperature panels read
# `router_*` metrics from an optional extra collector on the router
# (`router_hnat_entries{family,state}`, `router_default_route{device}`,
# `router_softnet_dropped_total{cpu}`, `router_thermal_zone_celsius{zone}`);
# without it they stay empty.

locals {
  _owrt_target = try(local.platform.monitoring.openwrt_dashboard, "")
  _owrt_on     = local._owrt_target != ""
  _owrt_ds     = { type = "prometheus", uid = "prometheus" }
  _owrt_job    = "job=\"scrapeConfig/monitoring/${local._owrt_target}\""
  # Interfaces worth a line; the `device` variable narrows further.
  _owrt_dev = "device=~\"$device\""
}

resource "terraform_data" "openwrt_dashboard_checks" {
  for_each = local._owrt_on ? toset(["enabled"]) : toset([])

  lifecycle {
    precondition {
      condition     = contains(keys(local._external_targets), local._owrt_target)
      error_message = "monitoring.openwrt_dashboard names \"${local._owrt_target}\", which is not an entry of monitoring.external_targets."
    }
  }
}

resource "kubernetes_config_map_v1" "openwrt_dashboard" {
  for_each   = local._owrt_on ? toset(["enabled"]) : toset([])
  depends_on = [module.addons, terraform_data.openwrt_dashboard_checks]

  metadata {
    name      = "openwrt-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard              = "1"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "openwrt.json" = jsonencode({
      title         = "Router (OpenWrt)"
      uid           = "openwrt-router"
      schemaVersion = 39
      refresh       = "30s"
      time          = { from = "now-6h", to = "now" }
      templating = {
        list = [{
          name       = "device"
          label      = "Interfaces"
          type       = "query"
          datasource = local._owrt_ds
          query      = { query = "label_values(node_network_receive_bytes_total{${local._owrt_job}}, device)", refId = "device" }
          refresh    = 2
          multi      = true
          includeAll = true
          current    = { selected = true, text = ["All"], value = ["$__all"] }
          regex      = "/^(?!lo$|ifb|ip6tnl|sit|gre|erspan|teql).*/"
        }]
      }
      panels = [
        # ── At a glance ─────────────────────────────────────────────────────
        {
          type       = "stat"
          title      = "Active uplink"
          gridPos    = { x = 0, y = 0, w = 4, h = 4 }
          datasource = local._owrt_ds
          options    = { reduceOptions = { calcs = ["lastNotNull"], fields = "/^device$/" }, colorMode = "none", graphMode = "none", textMode = "value" }
          targets    = [{ refId = "A", datasource = local._owrt_ds, expr = "router_default_route{${local._owrt_job}} == 1", format = "table", instant = true }]
        },
        {
          type        = "stat"
          title       = "CPU busy"
          gridPos     = { x = 4, y = 0, w = 4, h = 4 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "percent", decimals = 0, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "orange", value = 60 }, { color = "red", value = 85 }] } } }
          options     = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "value", graphMode = "area" }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "100 * (1 - avg(rate(node_cpu_seconds_total{${local._owrt_job},mode=\"idle\"}[2m])))" }]
        },
        {
          type        = "stat"
          title       = "Conntrack used"
          gridPos     = { x = 8, y = 0, w = 4, h = 4 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "percent", decimals = 1, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "orange", value = 60 }, { color = "red", value = 80 }] } } }
          options     = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "value", graphMode = "area" }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "100 * node_nf_conntrack_entries{${local._owrt_job}} / node_nf_conntrack_entries_limit{${local._owrt_job}}" }]
        },
        {
          type        = "stat"
          title       = "Memory available"
          gridPos     = { x = 12, y = 0, w = 4, h = 4 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "bytes", decimals = 0 } }
          options     = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "none", graphMode = "area" }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "node_memory_MemAvailable_bytes{${local._owrt_job}}" }]
        },
        {
          type        = "stat"
          title       = "Temperature"
          gridPos     = { x = 16, y = 0, w = 4, h = 4 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "celsius", decimals = 0, thresholds = { mode = "absolute", steps = [{ color = "green", value = null }, { color = "orange", value = 75 }, { color = "red", value = 90 }] } } }
          options     = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "value", graphMode = "area" }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "max(router_thermal_zone_celsius{${local._owrt_job}})" }]
        },
        {
          type       = "stat"
          title      = "Hardware NAT flows (bound)"
          gridPos    = { x = 20, y = 0, w = 4, h = 4 }
          datasource = local._owrt_ds
          options    = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "none", graphMode = "none", textMode = "value_and_name" }
          targets    = [{ refId = "A", datasource = local._owrt_ds, expr = "router_hnat_entries{${local._owrt_job},state=\"bind\"}", legendFormat = "{{family}}" }]
        },
        # ── Traffic ─────────────────────────────────────────────────────────
        {
          type        = "timeseries"
          title       = "Received (bits/s)"
          gridPos     = { x = 0, y = 4, w = 12, h = 9 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "bps" } }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "8 * rate(node_network_receive_bytes_total{${local._owrt_job},${local._owrt_dev}}[2m])", legendFormat = "{{device}}" }]
        },
        {
          type        = "timeseries"
          title       = "Sent (bits/s)"
          gridPos     = { x = 12, y = 4, w = 12, h = 9 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "bps" } }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "8 * rate(node_network_transmit_bytes_total{${local._owrt_job},${local._owrt_dev}}[2m])", legendFormat = "{{device}}" }]
        },
        {
          type        = "timeseries"
          title       = "Dropped packets/s"
          gridPos     = { x = 0, y = 13, w = 12, h = 8 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "pps" } }
          targets = [
            { refId = "A", datasource = local._owrt_ds, expr = "rate(node_network_receive_drop_total{${local._owrt_job},${local._owrt_dev}}[2m]) > 0", legendFormat = "{{device}} rx" },
            { refId = "B", datasource = local._owrt_ds, expr = "rate(node_network_transmit_drop_total{${local._owrt_job},${local._owrt_dev}}[2m]) > 0", legendFormat = "{{device}} tx" },
          ]
        },
        {
          type        = "timeseries"
          title       = "Errors/s"
          gridPos     = { x = 12, y = 13, w = 12, h = 8 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "pps" } }
          targets = [
            { refId = "A", datasource = local._owrt_ds, expr = "rate(node_network_receive_errs_total{${local._owrt_job},${local._owrt_dev}}[2m]) > 0", legendFormat = "{{device}} rx" },
            { refId = "B", datasource = local._owrt_ds, expr = "rate(node_network_transmit_errs_total{${local._owrt_job},${local._owrt_dev}}[2m]) > 0", legendFormat = "{{device}} tx" },
          ]
        },
        # ── CPU ─────────────────────────────────────────────────────────────
        {
          type        = "timeseries"
          title       = "CPU by mode (all cores)"
          gridPos     = { x = 0, y = 21, w = 12, h = 8 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "percent", custom = { stacking = { mode = "normal" }, fillOpacity = 30 } } }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "100 * avg by (mode) (rate(node_cpu_seconds_total{${local._owrt_job},mode!~\"idle|guest|guest_nice\"}[2m]))", legendFormat = "{{mode}}" }]
        },
        {
          type        = "timeseries"
          title       = "softirq per core"
          gridPos     = { x = 12, y = 21, w = 12, h = 8 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "percent", max = 100 } }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "100 * rate(node_cpu_seconds_total{${local._owrt_job},mode=\"softirq\"}[2m])", legendFormat = "{{cpu}}" }]
        },
        # ── Forwarding internals ────────────────────────────────────────────
        {
          type        = "timeseries"
          title       = "Receive backlog drops/s per core"
          gridPos     = { x = 0, y = 29, w = 8, h = 8 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = { unit = "pps" } }
          targets     = [{ refId = "A", datasource = local._owrt_ds, expr = "rate(router_softnet_dropped_total{${local._owrt_job}}[2m])", legendFormat = "cpu{{cpu}}" }]
        },
        {
          type       = "timeseries"
          title      = "Hardware NAT table"
          gridPos    = { x = 8, y = 29, w = 8, h = 8 }
          datasource = local._owrt_ds
          targets    = [{ refId = "A", datasource = local._owrt_ds, expr = "router_hnat_entries{${local._owrt_job}}", legendFormat = "{{family}} {{state}}" }]
        },
        {
          type       = "timeseries"
          title      = "Conntrack entries"
          gridPos    = { x = 16, y = 29, w = 8, h = 8 }
          datasource = local._owrt_ds
          targets = [
            { refId = "A", datasource = local._owrt_ds, expr = "node_nf_conntrack_entries{${local._owrt_job}}", legendFormat = "entries" },
            { refId = "B", datasource = local._owrt_ds, expr = "node_nf_conntrack_entries_limit{${local._owrt_job}}", legendFormat = "limit" },
          ]
        },
        {
          type        = "timeseries"
          title       = "Load and memory"
          gridPos     = { x = 0, y = 37, w = 24, h = 7 }
          datasource  = local._owrt_ds
          fieldConfig = { defaults = {}, overrides = [{ matcher = { id = "byName", options = "available memory" }, properties = [{ id = "unit", value = "bytes" }, { id = "custom.axisPlacement", value = "right" }] }] }
          targets = [
            { refId = "A", datasource = local._owrt_ds, expr = "node_load1{${local._owrt_job}}", legendFormat = "load 1m" },
            { refId = "B", datasource = local._owrt_ds, expr = "node_memory_MemAvailable_bytes{${local._owrt_job}}", legendFormat = "available memory" },
          ]
        },
      ]
    })
  }
}
