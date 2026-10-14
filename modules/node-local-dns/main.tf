# NodeLocal DNSCache — a DNS cache on every node (KEP-1024).
#
# A DaemonSet in the host network binds `local_ip` and the cluster DNS
# Service address on a dummy interface of each node and adds NOTRACK rules,
# so pods' queries to the cluster DNS address are answered on their own node
# without any kubelet change. Misses go to the cluster DNS pods through the
# `kube-dns-upstream` Service. A node keeps resolving names it has seen when
# the cluster DNS pods or the network to them fail, and nodes far from the
# DNS pods stop paying the round trip on every lookup.
#
# On a clean stop the cache removes its rules and queries fall back to the
# cluster DNS Service. A crash leaves them until the DaemonSet restarts it.

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
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Null while disabled; the precondition below requires it when enabled.
  cluster_dns_ip = var.cluster_dns_ip == null ? "" : var.cluster_dns_ip

  labels = {
    "k8s-app"                      = "node-local-dns"
    "app.kubernetes.io/managed-by" = "terraform"
  }

  # The node-cache binary replaces __PILLAR__CLUSTER__DNS__ with the
  # `kube-dns-upstream` ClusterIP (`-upstreamsvc`) and
  # __PILLAR__UPSTREAM__SERVERS__ with the node's resolvers.
  external_upstream = var.external_via_cluster_dns ? "__PILLAR__CLUSTER__DNS__ {\n        force_tcp\n    }" : "__PILLAR__UPSTREAM__SERVERS__"

  cache = <<-EOT
    cache {
            success 9984 30
            denial 9984 5%{if var.serve_stale != ""}
            serve_stale ${var.serve_stale}%{endif}
        }
  EOT

  corefile = <<-EOT
    ${var.cluster_domain}:53 {
        errors
        ${trimspace(local.cache)}
        reload
        loop
        bind ${var.local_ip} ${local.cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus {$HOST_IP}:9253
        health ${var.local_ip}:8080
    }
    in-addr.arpa:53 {
        errors
        ${trimspace(local.cache)}
        reload
        loop
        bind ${var.local_ip} ${local.cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus {$HOST_IP}:9253
    }
    ip6.arpa:53 {
        errors
        ${trimspace(local.cache)}
        reload
        loop
        bind ${var.local_ip} ${local.cluster_dns_ip}
        forward . __PILLAR__CLUSTER__DNS__ {
            force_tcp
        }
        prometheus {$HOST_IP}:9253
    }
    .:53 {
        errors
        ${trimspace(local.cache)}
        reload
        loop
        bind ${var.local_ip} ${local.cluster_dns_ip}
        forward . ${local.external_upstream}
        prometheus {$HOST_IP}:9253
    }
  EOT
}

resource "terraform_data" "preconditions" {
  for_each = local.instances

  lifecycle {
    precondition {
      condition     = var.cluster_dns_ip != null
      error_message = "cluster_dns_ip is required when the cache is enabled."
    }
  }
}

resource "kubernetes_service_account_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "node-local-dns"
    namespace = var.namespace
    labels    = local.labels
  }
}

# The cache cannot forward to the cluster DNS Service address: it binds that
# address itself. This second Service selects the same DNS pods.
resource "kubernetes_service_v1" "upstream" {
  for_each = local.instances

  metadata {
    name      = "kube-dns-upstream"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector = var.cluster_dns_selector

    port {
      name        = "dns"
      port        = 53
      protocol    = "UDP"
      target_port = 53
    }
    port {
      name        = "dns-tcp"
      port        = 53
      protocol    = "TCP"
      target_port = 53
    }
  }
}

resource "kubernetes_config_map_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "node-local-dns"
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    Corefile = local.corefile
  }
}

resource "kubernetes_daemon_set_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "node-local-dns"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    selector {
      match_labels = { "k8s-app" = "node-local-dns" }
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        # One node at a time: a node whose cache is restarting falls back to
        # the cluster DNS Service.
        max_unavailable = 1
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          # The cache reloads a changed Corefile (`reload`), but the
          # template still changes with it so a rollout is visible.
          "checksum/corefile" = sha256(local.corefile)
        }
      }

      spec {
        priority_class_name  = "system-node-critical"
        service_account_name = kubernetes_service_account_v1.this["enabled"].metadata[0].name
        host_network         = true
        dns_policy           = "Default" # resolve through the node, not through itself
        node_selector        = var.node_selector

        # Every node, tainted or not: a node without the cache would still
        # resolve, but this is the point of the DaemonSet.
        toleration {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        }
        toleration {
          effect   = "NoExecute"
          operator = "Exists"
        }
        toleration {
          effect   = "NoSchedule"
          operator = "Exists"
        }

        container {
          name  = "node-cache"
          image = var.image
          args = [
            "-localip", "${var.local_ip},${local.cluster_dns_ip}",
            "-conf", "/etc/Corefile",
            "-upstreamsvc", kubernetes_service_v1.upstream["enabled"].metadata[0].name,
            "-metrics-listen-address", "$(HOST_IP):9353",
          ]

          # Metrics listen on the node's own address, not on every address
          # of the host network (nodes may have public ones). CoreDNS reads
          # it in the Corefile as {$HOST_IP}.
          env {
            name = "HOST_IP"
            value_from {
              field_ref {
                field_path = "status.hostIP"
              }
            }
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # Creates the dummy interface and the NOTRACK rules.
          security_context {
            capabilities {
              add = ["NET_ADMIN"]
            }
          }

          port {
            name           = "dns"
            container_port = 53
            protocol       = "UDP"
          }
          port {
            name           = "dns-tcp"
            container_port = 53
            protocol       = "TCP"
          }
          port {
            name           = "metrics"
            container_port = 9253
            protocol       = "TCP"
          }

          liveness_probe {
            http_get {
              host = var.local_ip
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 60
            timeout_seconds       = 5
          }

          volume_mount {
            name       = "xtables-lock"
            mount_path = "/run/xtables.lock"
          }
          volume_mount {
            name       = "config"
            mount_path = "/etc/coredns"
          }
        }

        volume {
          name = "xtables-lock"
          host_path {
            path = "/run/xtables.lock"
            type = "FileOrCreate"
          }
        }
        # The binary renders /etc/Corefile from this base file.
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.this["enabled"].metadata[0].name
            items {
              key  = "Corefile"
              path = "Corefile.base"
            }
          }
        }
      }
    }
  }
}

resource "kubectl_manifest" "pod_monitor" {
  for_each = local.instances

  depends_on = [kubernetes_daemon_set_v1.this]

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PodMonitor"
    metadata = {
      name      = "node-local-dns"
      namespace = var.namespace
      labels    = merge(local.labels, var.prometheus_selector_labels)
    }
    spec = {
      selector            = { matchLabels = { "k8s-app" = "node-local-dns" } }
      podMetricsEndpoints = [{ port = "metrics" }]
    }
  })
}
