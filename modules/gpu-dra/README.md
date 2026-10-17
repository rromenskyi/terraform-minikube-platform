# gpu-dra

Installs [`ipsupport-llc/dra-driver-dri`](https://github.com/ipsupport-llc/dra-driver-dri):
a Kubernetes DRA kubelet plugin that publishes every DRM render-node GPU
(`/dev/dri/renderD*`) with a consumable `vram` capacity. Pods claim an amount
of VRAM; the scheduler places them on a node and GPU with room, so several pods
share one GPU. Each pod gets exactly one render node through CDI — no
privileges, no `hostPath` in the workload.

What it creates (when `enabled`): namespace, ServiceAccount, ClusterRole and
binding, the plugin DaemonSet on nodes matching `node_selector`, a DeviceClass
named `driver_name`, a PodMonitor (adds a `node` label), a PrometheusRule, a
ValidatingAdmissionPolicy that limits the plugin to its own node's
ResourceSlices, and a Grafana dashboard ConfigMap (`grafana_dashboard=1`):
claimed, used and offered VRAM, VRAM evicted to RAM (GTT), temperature and
clocks per node and GPU.

## Configuration (`platform.yaml`)

```yaml
services:
  gpu_dra:
    enabled: true
    driver_name: gpu.example.com   # a DNS subdomain you own; also the DeviceClass name
    # node_selector: { gpu: dri }  # label your GPU nodes with it
    # vram_reserve: 256Mi          # held back per GPU for the kernel driver
```

## Claiming VRAM

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: vram-2gi
spec:
  spec:
    devices:
      requests:
        - name: gpu
          exactly:
            deviceClassName: gpu.example.com
            capacity:
              requests:
                vram: 2Gi
```

Reference the template from the pod's `resourceClaims` and the container's
`resources.claims`. A claim without a `vram` amount gets the whole GPU. VRAM
is not enforced by the kernel: size models and contexts to the
`DRA_GPU_VRAM_BYTES` environment variable the container receives.

## Alerts

`DRIPrepareErrors`, `DRIVRAMOverUse` (used > claimed + reserve for 10 min),
`DRIVRAMNearlyFull` (> 95 %), `DRIVRAMEvictedToRAM` (GTT > 1 GiB while VRAM
is over 90 % used, for 5 min), and `DRIPluginMissing`. The last one fires
only when **no** plugin pod is up anywhere: a per-node check would need node
labels in kube-state-metrics (`kube_node_labels`), which are not exported by
default.
