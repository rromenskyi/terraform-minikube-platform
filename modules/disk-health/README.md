# disk-health

SMART data of the cluster nodes' physical drives in Prometheus and
Grafana, next to what writes to them.

## Shape

- **Exporter.** [`smartctl_exporter`](https://github.com/prometheus-community/smartctl_exporter)
  runs as a DaemonSet from the upstream `prometheus-smartctl-exporter`
  chart, privileged and as root (reading a SMART log is a raw device
  ioctl). Its ServiceMonitor adds a `node` label, so series survive pod
  restarts under the same node/device pair. Virtual disks have no SMART
  data; on a cluster that mixes VMs and bare metal, set `affinity` to the
  bare-metal nodes.
- **Dashboard.** With `grafana_dashboard_enabled`, a ConfigMap labelled
  `grafana_dashboard=1` adds "Disk health" (uid `disk-health`):
  - a table per drive: model, wear %, days left, TB written, spare %,
    media errors, temperature, power-on days;
  - wear and bytes written per day over time;
  - disk write rate and average write latency per node (node_exporter);
  - the top writing namespaces per node (cAdvisor) and drive temperature.

"Days left" needs no rated endurance: bytes written per percent of wear
(from the drive's own counters) times the percent left, divided by the
last 3 days' write rate. It moves with the workload — it answers "how long
at this pace", not "how long at all". Drives that do not report
`percentage_used` (most SATA drives expose wear differently) are left out
of the table.

## Usage

```hcl
module "disk_health" {
  source = "./modules/disk-health"

  context                   = module.platform_label.context
  enabled                   = true
  grafana_dashboard_enabled = true
  affinity = {
    nodeAffinity = {
      requiredDuringSchedulingIgnoredDuringExecution = {
        nodeSelectorTerms = [{
          matchExpressions = [{ key = "kubernetes.io/hostname", operator = "In", values = ["node-a", "node-b"] }]
        }]
      }
    }
  }
}
```

Alerts are not part of the module yet; the chart's own rules
(`prometheusRules`) are left off.
