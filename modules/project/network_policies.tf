# Per-project NetworkPolicy presets (`network_policies:` in the domain yaml
# env). The application's pods are deployed by Argo CD, so the engine can't
# see them: each entry names its pods by labels, and picks ready-made rules
# whose addresses and labels the platform knows (var.network_policy_targets).
#
#   network_policies:
#     edge-only:
#       pods:    { app.kubernetes.io/name: [web, ingest] }
#       ingress: [traefik, monitoring]          # only these may connect
#     worker-egress:
#       pods:    { app.kubernetes.io/name: [worker] }
#       egress:  [dns, postgres, mail_relay, internet]
#
# `ingress`/`egress` absent = that direction isn't restricted; an empty list
# = everything in that direction is denied. kubelet probes from the node are
# allowed by the CNI (kube-router) without a rule.

locals {
  network_policy_ingress_presets = ["traefik", "monitoring", "same_namespace"]
  network_policy_egress_presets  = ["dns", "postgres", "mail_relay", "internet", "same_namespace"]
}

resource "kubernetes_network_policy_v1" "preset" {
  for_each = var.network_policies

  depends_on = [kubernetes_namespace_v1.this]

  lifecycle {
    precondition {
      condition = (
        length(try(each.value.pods, {})) > 0 &&
        alltrue([for k, v in try(each.value.pods, {}) : can(tolist(v)) && length(v) > 0]) &&
        alltrue([for p in try(each.value.ingress, []) : contains(local.network_policy_ingress_presets, p)]) &&
        alltrue([for p in try(each.value.egress, []) : contains(local.network_policy_egress_presets, p)]) &&
        (try(each.value.ingress, null) != null || try(each.value.egress, null) != null)
      )
      error_message = "network_policies.${each.key} in project '${local.namespace}': needs `pods` (label: [values]) and at least one of `ingress` (${join(", ", local.network_policy_ingress_presets)}) / `egress` (${join(", ", local.network_policy_egress_presets)})."
    }
    precondition {
      condition     = !contains(try(each.value.egress, []), "postgres") || var.network_policy_targets.postgres != null
      error_message = "network_policies.${each.key} in project '${local.namespace}': `postgres` needs the shared CNPG Postgres."
    }
    precondition {
      condition     = !contains(try(each.value.egress, []), "mail_relay") || length(var.network_policy_targets.mail_relay_cidrs) > 0
      error_message = "network_policies.${each.key} in project '${local.namespace}': `mail_relay` needs `network_policies.mail_relay_cidrs` in platform.yaml."
    }
  }

  metadata {
    name      = each.key
    namespace = local.namespace
    labels    = module.project_label.tags
  }

  spec {
    pod_selector {
      dynamic "match_expressions" {
        for_each = try(each.value.pods, {})
        content {
          key      = match_expressions.key
          operator = "In"
          values   = match_expressions.value
        }
      }
    }

    policy_types = concat(
      try(each.value.ingress, null) != null ? ["Ingress"] : [],
      try(each.value.egress, null) != null ? ["Egress"] : [],
    )

    # ── ingress ──
    dynamic "ingress" {
      for_each = contains(try(each.value.ingress, []), "traefik") ? [1] : []
      content {
        from {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = var.network_policy_targets.traefik_namespace }
          }
        }
      }
    }
    dynamic "ingress" {
      for_each = contains(try(each.value.ingress, []), "monitoring") ? [1] : []
      content {
        from {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = var.network_policy_targets.monitoring_namespace }
          }
        }
      }
    }
    dynamic "ingress" {
      for_each = contains(try(each.value.ingress, []), "same_namespace") ? [1] : []
      content {
        from {
          pod_selector {}
        }
      }
    }

    # ── egress ──
    dynamic "egress" {
      for_each = contains(try(each.value.egress, []), "dns") ? [1] : []
      content {
        to {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
          }
          pod_selector {
            match_labels = { "k8s-app" = "kube-dns" }
          }
        }
        ports {
          protocol = "UDP"
          port     = "53"
        }
        ports {
          protocol = "TCP"
          port     = "53"
        }
      }
    }
    dynamic "egress" {
      for_each = contains(try(each.value.egress, []), "postgres") && var.network_policy_targets.postgres != null ? [var.network_policy_targets.postgres] : []
      content {
        to {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = egress.value.namespace }
          }
          pod_selector {
            match_labels = egress.value.pod_labels
          }
        }
        ports {
          protocol = "TCP"
          port     = "5432"
        }
      }
    }
    dynamic "egress" {
      for_each = contains(try(each.value.egress, []), "mail_relay") ? [1] : []
      content {
        dynamic "to" {
          for_each = var.network_policy_targets.mail_relay_cidrs
          content {
            ip_block {
              cidr = to.value
            }
          }
        }
        ports {
          protocol = "TCP"
          port     = "25"
        }
      }
    }
    dynamic "egress" {
      for_each = contains(try(each.value.egress, []), "internet") ? [1] : []
      content {
        to {
          ip_block {
            cidr   = "0.0.0.0/0"
            except = var.network_policy_targets.internet_except
          }
        }
      }
    }
    dynamic "egress" {
      for_each = contains(try(each.value.egress, []), "same_namespace") ? [1] : []
      content {
        to {
          pod_selector {}
        }
      }
    }
  }
}
