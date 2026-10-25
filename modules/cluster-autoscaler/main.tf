# cluster-autoscaler for power-managed node pools.
#
# Upstream cluster-autoscaler with the externalgrpc cloud provider, served
# by plugpool (github.com/ipsupport-llc/plugpool) as a sidecar in the same
# pod over localhost: no network exposure, no TLS. plugpool treats each
# node group like a cloud node pool with a minimum of zero — it switches a
# machine's ESPHome smart plug on for a scale-up, and for a scale-down
# shuts the machine down through a one-shot privileged pod, then switches
# the plug off and deletes the Node. Its safety rules (only configured
# plugs, never a node cluster-autoscaler has not marked for deletion) are
# in plugpool's README.
#
# The plugs' web password comes from Vault through the Vault Secrets
# Operator (Secret `plugpool-plugs`), with a narrow role when given.

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
  instances    = var.enabled ? toset(["enabled"]) : toset([])
  app_labels   = { "app.kubernetes.io/name" = "cluster-autoscaler" }
  vault_auth   = "vault-plugpool"
  plug_secret  = "plugpool-plugs"
  config_mount = "/etc/plugpool"

  # plugpool's configuration (see its README).
  plugpool_config = yamlencode({
    listen           = "127.0.0.1:8086"
    providerIDPrefix = var.provider_id_prefix
    powerOff = {
      namespace = var.namespace
      image     = var.poweroff_image
    }
    nodeGroups = [for g in var.node_groups : {
      id      = g.id
      minSize = g.min_size
      maxSize = g.max_size
      template = {
        cpu    = g.template.cpu
        memory = g.template.memory
        pods   = g.template.pods
        labels = g.template.labels
        taints = g.template.taints
      }
      nodes = [for n in g.nodes : { name = n.name, plug = { url = n.plug_url, switch = n.plug_switch } }]
    }]
  })

  # externalgrpc cloud-config: plugpool in the same pod. grpc_timeout above
  # the 5s default: a Refresh reads every plug.
  cloud_config = yamlencode({ address = "127.0.0.1:8086", grpc_timeout = "15s" })
}

module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "cluster-autoscaler"
  tags = {
    "app.kubernetes.io/component" = "cluster-autoscaler"
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.instances

  metadata {
    name = var.namespace
    labels = merge(module.label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
      # The poweroff pods are privileged with host PID.
      "pod-security.kubernetes.io/enforce" = "privileged"
    })
  }
}

resource "kubernetes_service_account_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = module.label.tags
  }
}

# cluster-autoscaler's rules (upstream Helm chart 9.59.0) plus plugpool's:
# delete the Node objects of powered-off machines.
resource "kubernetes_cluster_role_v1" "this" {
  for_each = local.instances

  metadata {
    name   = "cluster-autoscaler-${var.namespace}"
    labels = module.label.tags
  }

  dynamic "rule" {
    for_each = [
      { groups = [""], resources = ["events", "endpoints"], verbs = ["create", "patch"], names = [] },
      { groups = [""], resources = ["pods/eviction"], verbs = ["create"], names = [] },
      { groups = [""], resources = ["pods/status"], verbs = ["update"], names = [] },
      { groups = [""], resources = ["endpoints"], verbs = ["get", "update"], names = ["cluster-autoscaler"] },
      { groups = [""], resources = ["nodes"], verbs = ["watch", "list", "get", "update", "delete"], names = [] },
      { groups = [""], resources = ["podtemplates"], verbs = ["get", "list", "watch", "create", "update", "patch"], names = [] },
      { groups = ["resource.k8s.io"], resources = ["resourceslices", "deviceclasses", "resourceclaims"], verbs = ["watch", "list", "get"], names = [] },
      { groups = [""], resources = ["namespaces", "pods", "services", "replicationcontrollers", "persistentvolumeclaims", "persistentvolumes"], verbs = ["watch", "list", "get"], names = [] },
      { groups = ["batch"], resources = ["jobs", "cronjobs"], verbs = ["watch", "list", "get"], names = [] },
      { groups = ["batch", "extensions"], resources = ["jobs"], verbs = ["get", "list", "patch", "watch"], names = [] },
      { groups = ["extensions"], resources = ["replicasets", "daemonsets"], verbs = ["watch", "list", "get"], names = [] },
      { groups = ["policy"], resources = ["poddisruptionbudgets"], verbs = ["watch", "list"], names = [] },
      { groups = ["apps"], resources = ["daemonsets", "deployments", "replicasets", "statefulsets"], verbs = ["watch", "list", "get"], names = [] },
      { groups = ["storage.k8s.io"], resources = ["storageclasses", "csinodes", "csidrivers", "csistoragecapacities", "volumeattachments"], verbs = ["watch", "list", "get"], names = [] },
      { groups = [""], resources = ["configmaps"], verbs = ["list", "watch", "get"], names = [] },
      { groups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["create"], names = [] },
      { groups = ["coordination.k8s.io"], resources = ["leases"], verbs = ["get", "update"], names = ["cluster-autoscaler"] },
    ]
    content {
      api_groups     = rule.value.groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = length(rule.value.names) > 0 ? rule.value.names : null
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  for_each = local.instances

  metadata {
    name   = "cluster-autoscaler-${var.namespace}"
    labels = module.label.tags
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this["enabled"].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

# cluster-autoscaler's status ConfigMap; plugpool's poweroff pods (found by
# label, so list).
resource "kubernetes_role_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = module.label.tags
  }
  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["create"]
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = ["cluster-autoscaler-status"]
    verbs          = ["delete", "get", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["create", "list", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = module.label.tags
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.this["enabled"].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_config_map_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = module.label.tags
  }
  data = {
    "cloud-config.yaml" = local.cloud_config
    "plugpool.yaml"     = local.plugpool_config
  }
}

# ── Plug password from Vault (VSO) ──────────────────────────────────────────

# VSO impersonates this SA in the namespace of the VaultStaticSecret.
resource "kubernetes_service_account_v1" "vso_proxy" {
  for_each = local.instances

  metadata {
    name      = "vault-secrets-operator-controller-manager"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels = merge(module.label.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
    })
  }
}

resource "kubectl_manifest" "vault_auth" {
  for_each = var.enabled && var.vault_auth_role != "" ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = local.vault_auth
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = module.label.tags
    }
    spec = {
      method = "kubernetes"
      mount  = "kubernetes"
      kubernetes = {
        role                   = var.vault_auth_role
        serviceAccount         = kubernetes_service_account_v1.vso_proxy["enabled"].metadata[0].name
        tokenExpirationSeconds = 600
      }
    }
  })
}

# Key `password` of `vault_path` → Secret `plugpool-plugs`. A password
# change restarts the pod.
resource "kubectl_manifest" "plug_secret" {
  for_each = local.instances

  depends_on = [kubernetes_service_account_v1.vso_proxy, kubectl_manifest.vault_auth]

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = local.plug_secret
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = module.label.tags
    }
    # Without a role, no vaultAuthRef at all: VSO's default VaultAuth.
    spec = merge(var.vault_auth_role != "" ? { vaultAuthRef = local.vault_auth } : {}, {
      mount = "secret"
      type  = "kv-v2"
      path  = var.vault_path
      destination = {
        name   = local.plug_secret
        create = true
        transformation = {
          excludeRaw = true
          excludes   = [".*"]
          templates  = { password = { text = "{{- get .Secrets \"password\" -}}" } }
        }
      }
      rolloutRestartTargets = [{ kind = "Deployment", name = "cluster-autoscaler" }]
      refreshAfter          = "60s"
    })
  })

  lifecycle {
    precondition {
      condition     = var.vault_path != ""
      error_message = "cluster-autoscaler: vault_path is required (the plugs' web password)."
    }
  }
}

# ── Deployment ──────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  for_each = local.instances

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(module.label.tags, local.app_labels)
  }

  spec {
    replicas = 1
    # One autoscaler at a time; a scale-down in progress is not resumed by
    # a new pod (cluster-autoscaler retries it as an unready node).
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.app_labels
    }

    template {
      metadata {
        labels = merge(module.label.tags, local.app_labels)
        annotations = {
          # Never drain the node the autoscaler itself runs on.
          "cluster-autoscaler.kubernetes.io/safe-to-evict" = "false"
          "checksum/config"                                = sha256("${local.cloud_config}${local.plugpool_config}")
        }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.this["enabled"].metadata[0].name
        # Not preempted in the middle of a scale-down.
        priority_class_name              = "system-cluster-critical"
        node_selector                    = var.node_selector
        termination_grace_period_seconds = 60

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key      = toleration.value.key
            operator = toleration.value.operator
            value    = toleration.value.value
            effect   = toleration.value.effect
          }
        }

        container {
          name    = "cluster-autoscaler"
          image   = var.ca_image
          command = ["./cluster-autoscaler"]
          args = [
            "--cloud-provider=externalgrpc",
            "--cloud-config=${local.config_mount}/cloud-config.yaml",
            "--namespace=${var.namespace}",
            "--scale-down-unneeded-time=${var.scale_down_unneeded_time}",
            "--scale-down-delay-after-add=${var.scale_down_delay_after_add}",
            "--max-node-provision-time=${var.max_node_provision_time}",
            "--skip-nodes-with-system-pods=false",
            # Pods with emptyDir would otherwise keep a machine on forever.
            "--skip-nodes-with-local-storage=false",
            "--v=2",
          ]
          port {
            name           = "metrics"
            container_port = 8085
          }
          liveness_probe {
            http_get {
              path = "/health-check"
              port = "metrics"
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 6
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 65532
            capabilities {
              drop = ["ALL"]
            }
          }
          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { cpu = "500m", memory = "512Mi" }
          }
          volume_mount {
            name       = "config"
            mount_path = local.config_mount
            read_only  = true
          }
        }

        container {
          name  = "plugpool"
          image = var.plugpool_image
          args  = ["--config=${local.config_mount}/plugpool.yaml"]
          env {
            name  = "PLUGPOOL_PLUG_USERNAME"
            value = var.plug_username
          }
          env {
            name = "PLUGPOOL_PLUG_PASSWORD"
            value_from {
              secret_key_ref {
                name = local.plug_secret
                key  = "password"
              }
            }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }
          volume_mount {
            name       = "config"
            mount_path = local.config_mount
            read_only  = true
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.this["enabled"].metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.plug_secret, kubernetes_role_binding_v1.this, kubernetes_cluster_role_binding_v1.this]
}

# ── Metrics ─────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "metrics" {
  for_each = var.enabled && var.monitoring ? toset(["enabled"]) : toset([])

  metadata {
    name      = "cluster-autoscaler"
    namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
    labels    = merge(module.label.tags, local.app_labels)
  }
  spec {
    selector = local.app_labels
    port {
      name        = "metrics"
      port        = 8085
      target_port = "metrics"
    }
  }
}

resource "kubectl_manifest" "service_monitor" {
  for_each = var.enabled && var.monitoring ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "cluster-autoscaler"
      namespace = kubernetes_namespace_v1.this["enabled"].metadata[0].name
      labels    = merge(module.label.tags, var.prometheus_selector_labels)
    }
    spec = {
      selector  = { matchLabels = local.app_labels }
      endpoints = [{ port = "metrics", interval = "30s" }]
    }
  })
}
