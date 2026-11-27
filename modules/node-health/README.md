# node-health

Keeps new pods off a node whose kernel has hung tasks, and alerts.

A node can stay `Ready` while part of its kernel is stuck: a GPU job that
never finishes, a storage or NFS stall. Processes stuck in the kernel
(state D) cannot be killed, pods scheduled there hang too, and the kubelet
still answers, so Kubernetes sees nothing wrong.

## Shape

- **Detection.** [node-problem-detector](https://github.com/kubernetes/node-problem-detector)
  runs as a privileged DaemonSet on every node and reads the kernel log.
  `kernel-monitor.json` is the stock kernel monitor of the pinned image
  with one change: `task ... blocked for more than N seconds` sets the node
  condition `KernelDeadlock=True` (reason `TaskHung`) instead of only
  emitting an event. The stock Docker and read-only monitors are left out.
- **Taint.** [node-readiness-controller](https://github.com/kubernetes-sigs/node-readiness-controller)
  (SIG Node, alpha) keeps `readiness.k8s.io/KernelDeadlock=hung-tasks:NoSchedule`
  on a node while `KernelDeadlock` is True and removes it when it clears.
  Running pods stay; new ones go elsewhere. A taint rather than
  `spec.unschedulable`, so it never fights kured or a manual cordon.
  With `dry_run` (the default) the rule only reports in its
  `status.dryRunResults` what it would taint.
- **Alerts** (from kube-state-metrics): `NodeKernelDeadlock` (critical),
  `NodeKernelDeadlockSeveralNodes` (more than one node at once: look at
  shared storage first), `NodeProblemDetectorUnavailable`.

## Clearing

The condition is permanent until node-problem-detector restarts:

- after a **reboot** (the usual fix for hung tasks), node-problem-detector
  starts with the condition False and the taint goes;
- after a **transient stall**, delete the node-problem-detector pod on
  that node. It re-reads only the last five minutes of the kernel log, so
  wait until five minutes after the last hung-task line.

Any restart of node-problem-detector clears the condition the same way,
including a chart or image rollout: if the node is still hung but printed
its last hung-task line more than five minutes earlier, the taint goes and
`NodeKernelDeadlock` resolves. Reboot a node that raised the alert rather
than waiting for it to resolve.

Other DaemonSets do not tolerate the taint: a pod of theirs replaced on a
tainted node (rollout, crash with a new pod) stays Pending until the node
reboots. The GPU plugin (gpu-dra) tolerates it, since it must keep a hung
node's GPUs tainted. Deleting the rule (or `enabled = false`) removes its
taints through the controller's finalizer.

The kernel prints at most `kernel.hung_task_warnings` (default 10)
hung-task lines per boot. Once they are used up, a later hang in the same
boot prints nothing and is not detected.

## Usage

```hcl
module "node_health" {
  source = "./modules/node-health"

  enabled = true
  dry_run = false
}
```

`enabled` installs both components, the NodeReadinessRule and the
PrometheusRule into `namespace` (default `kube-system`). `node_selector`
limits which nodes the taint rule covers (default: every Linux node;
node-readiness-controller rejects an empty selector). Workloads that must
still start on such a node tolerate the key in output `taint_key`.

Do not add `NodeKernelDeadlock` to kured's blocking alerts: it fires until
the reboot that fixes it.

## Inputs

| Name | Default | Meaning |
|---|---|---|
| `enabled` | `false` | install everything; false removes everything |
| `namespace` | `kube-system` | existing namespace for both components and the rules |
| `node_selector` | `{"kubernetes.io/os" = "linux"}` | nodes the taint rule covers; must not be empty; immutable |
| `dry_run` | `true` | report instead of tainting |
| `npd_chart_version` | `2.4.2` | deliveryhero `node-problem-detector` chart |
| `npd_image_repository`, `npd_image_tag` | `registry.k8s.io/...`, `v1.37.0@sha256:...` | node-problem-detector image, digest-pinned |
| `npd_resources` | 10m / 40Mi, limit 128Mi | node-problem-detector container resources |
| `nrc_chart_version` | `0.6.0` | `node-readiness-controller` chart (image follows it) |
| `prometheus_selector_labels` | `{release = "kube-prometheus-stack"}` | labels Prometheus selects rules by |

## Outputs

| Name | Meaning |
|---|---|
| `taint_key` | key of the hung-node taint; null when disabled |
| `namespace` | namespace of the components; empty when disabled |
