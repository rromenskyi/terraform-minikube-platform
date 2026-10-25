# Grafana dashboard for ESPHome smart plugs with power monitoring (scraped
# through `monitoring.external_targets`, see external_scrape.tf): power,
# voltage, relay state and today's energy per plug. Series are named by the
# target label `plug` (set it on every target in external_targets).
#
#   monitoring:
#     esphome_power_dashboard: true
#
# The Grafana sidecar of kube-prometheus-stack loads ConfigMaps labelled
# `grafana_dashboard: "1"`.

locals {
  _esphome_dash_on = try(local.platform.monitoring.esphome_power_dashboard, false)
  _esphome_ds      = { type = "prometheus", uid = "prometheus" }
}

resource "kubernetes_config_map_v1" "esphome_power_dashboard" {
  for_each   = local._esphome_dash_on ? toset(["enabled"]) : toset([])
  depends_on = [module.addons]

  metadata {
    name      = "esphome-power-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard              = "1"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "esphome-power.json" = jsonencode({
      title         = "Power (ESPHome plugs)"
      uid           = "esphome-power"
      schemaVersion = 39
      refresh       = "30s"
      time          = { from = "now-24h", to = "now" }
      panels = [
        {
          type        = "stat"
          title       = "Now"
          gridPos     = { x = 0, y = 0, w = 24, h = 4 }
          datasource  = local._esphome_ds
          fieldConfig = { defaults = { unit = "watt", decimals = 1 } }
          options     = { reduceOptions = { calcs = ["lastNotNull"] }, colorMode = "value", graphMode = "area" }
          # Only plugs still reporting at the end of the range (`@ end()`):
          # otherwise a renamed or removed plug stays on as a stale tile with
          # its last value.
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug) (esphome_sensor_value{id=\"power\"}) and on (plug) max by (plug) (esphome_sensor_value{id=\"power\"} @ end())"
            legendFormat = "{{plug}}"
          }]
        },
        {
          type        = "timeseries"
          title       = "Power"
          gridPos     = { x = 0, y = 4, w = 24, h = 9 }
          datasource  = local._esphome_ds
          fieldConfig = { defaults = { unit = "watt" } }
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug, node) (esphome_sensor_value{id=\"power\"})"
            legendFormat = "{{plug}}"
          }]
        },
        {
          type        = "timeseries"
          title       = "Voltage"
          gridPos     = { x = 0, y = 13, w = 12, h = 7 }
          datasource  = local._esphome_ds
          fieldConfig = { defaults = { unit = "volt" } }
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug, node) (esphome_sensor_value{id=\"voltage\"})"
            legendFormat = "{{plug}}"
          }]
        },
        # Energy since local midnight, computed here: the plugs' own
        # `total_daily_energy` resets only when the plug has valid time, so
        # without it the counter just grows from the plug's last boot.
        # increase() also absorbs the counter's resets (midnight on the
        # plug, reboots). The panel's own range is "today so far".
        {
          type        = "bargauge"
          title       = "Energy today"
          gridPos     = { x = 12, y = 13, w = 12, h = 7 }
          datasource  = local._esphome_ds
          timeFrom    = "now/d"
          fieldConfig = { defaults = { unit = "kwatth", decimals = 2 } }
          options     = { orientation = "horizontal", reduceOptions = { calcs = ["lastNotNull"] } }
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug, node) (increase(esphome_sensor_value{id=\"total_daily_energy\"}[$__range]))"
            instant      = true
            legendFormat = "{{plug}}"
          }]
        },
        {
          type  = "state-timeline"
          title = "Relay (1 = on) and reachability"
          # Two rows per plug: ~25 px each, with a gap between rows.
          gridPos    = { x = 0, y = 20, w = 24, h = 20 }
          datasource = local._esphome_ds
          options    = { rowHeight = 0.8, mergeValues = true, showValue = "auto" }
          # Without an explicit color mode the state timeline uses its
          # continuous green-to-red default, which paints 1 (on / up) red.
          fieldConfig = {
            defaults = {
              min   = 0
              max   = 1
              color = { mode = "fixed", fixedColor = "text" }
              mappings = [{
                type = "value"
                options = {
                  "0" = { text = "off", color = "red", index = 0 }
                  "1" = { text = "on", color = "green", index = 1 }
                }
              }]
            }
            overrides = [{
              matcher = { id = "byFrameRefID", options = "B" }
              properties = [{
                id = "mappings"
                value = [{
                  type = "value"
                  options = {
                    "0" = { text = "down", color = "red", index = 0 }
                    "1" = { text = "up", color = "green", index = 1 }
                  }
                }]
              }]
            }]
          }
          targets = [
            {
              refId        = "A"
              datasource   = local._esphome_ds
              expr         = "max by (plug, node) (esphome_switch_value{id=~\"plug_.*|relay\"})"
              legendFormat = "relay {{plug}}"
            },
            {
              refId        = "B"
              datasource   = local._esphome_ds
              expr         = "max by (plug, instance) (up{job=~\"scrapeConfig/.*\", plug!=\"\"})"
              legendFormat = "reachable {{plug}}"
            },
          ]
        },
      ]
    })
  }
}
