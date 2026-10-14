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
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug, node) (esphome_sensor_value{id=\"power\"})"
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
        {
          type        = "bargauge"
          title       = "Energy today"
          gridPos     = { x = 12, y = 13, w = 12, h = 7 }
          datasource  = local._esphome_ds
          fieldConfig = { defaults = { unit = "kwatth", decimals = 2 } }
          options     = { orientation = "horizontal", reduceOptions = { calcs = ["lastNotNull"] } }
          targets = [{
            refId        = "A"
            datasource   = local._esphome_ds
            expr         = "max by (plug, node) (esphome_sensor_value{id=\"total_daily_energy\"})"
            legendFormat = "{{plug}}"
          }]
        },
        {
          type        = "state-timeline"
          title       = "Relay (1 = on) and reachability"
          gridPos     = { x = 0, y = 20, w = 24, h = 7 }
          datasource  = local._esphome_ds
          fieldConfig = { defaults = { min = 0, max = 1 } }
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
