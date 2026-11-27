# Node health: keep new pods off a node whose kernel has hung tasks.
#
# A node can stay `Ready` while part of its kernel is stuck: a GPU job
# that never finishes, a storage or NFS stall. Processes stuck in the
# kernel (state D) cannot be killed, and pods scheduled there hang too.
# Kubernetes sees nothing because the kubelet still answers.
#
# Two upstream components close the gap:
#
# - node-problem-detector (DaemonSet) reads the kernel log. Its stock
#   config only emits an event for "task ... blocked for more than N
#   seconds"; ours (`kernel-monitor.json`) turns it into the node condition
#   `KernelDeadlock=True`, which stays until node-problem-detector restarts
#   (after a reboot, or by deleting its pod on that node: it re-reads only
#   the last five minutes of the kernel log).
# - node-readiness-controller (SIG Node) keeps the taint
#   `readiness.k8s.io/KernelDeadlock:NoSchedule` on a node while its
#   condition is True and removes it when it clears. A taint instead of
#   `spec.unschedulable`, so it never fights kured or a manual cordon.
#
# Alerts come from kube-state-metrics (`kube_node_status_condition`), so
# node-problem-detector needs no scrape config.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

locals {
  set       = var.enabled ? toset(["enabled"]) : toset([])
  taint_key = "readiness.k8s.io/KernelDeadlock"
}
