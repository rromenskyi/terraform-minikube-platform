# cluster-autoscaler for power-managed node pools (modules/cluster-autoscaler).
#
# A node pool in `node_pools` becomes a cluster-autoscaler node group when
# it declares both blocks:
#
#   node_pools:
#     workers:
#       nodes: [worker-1, worker-2]
#       autoscaling:
#         min: 0
#         max: 2
#         template: { cpu: "24", memory: 60Gi }   # a machine's allocatable
#       power:
#         vault_path: platform/power-plugs        # key `password`
#         username: admin                         # optional
#         nodes:
#           worker-1: { url: "http://plug-worker-1.example", switch: "Relay" }
#
# Only the nodes listed under `power.nodes` are managed; other pool members
# are left alone. The template always carries the pool label, so workloads
# that select the pool trigger a scale-up.

locals {
  autoscaled_pools = { for name, p in local.platform.node_pools : name => p if try(p.autoscaling, null) != null }

  cluster_autoscaler_groups = [for name, p in local.autoscaled_pools : {
    id       = name
    min_size = p.autoscaling.min
    max_size = p.autoscaling.max
    template = {
      cpu    = p.autoscaling.template.cpu
      memory = p.autoscaling.template.memory
      pods   = try(p.autoscaling.template.pods, "110")
      labels = merge(try(p.autoscaling.template.labels, {}), { (local.platform.node_pool_label) = name })
      taints = try(p.autoscaling.template.taints, [])
    }
    nodes = [for n in sort(keys(try(p.power.nodes, {}))) : {
      name        = n
      plug_url    = p.power.nodes[n].url
      plug_switch = p.power.nodes[n].switch
    }]
  }]

  cluster_autoscaler_vault_paths = distinct([for p in values(local.autoscaled_pools) : try(p.power.vault_path, "")])
  cluster_autoscaler_vault_path  = length(local.cluster_autoscaler_vault_paths) == 1 ? local.cluster_autoscaler_vault_paths[0] : ""
  cluster_autoscaler_on          = local.platform.services.cluster_autoscaler.enabled && length(local.autoscaled_pools) > 0
}

# Pool declarations that cluster-autoscaler relies on, checked at plan time
# even while the service is off.
resource "terraform_data" "cluster_autoscaler_checks" {
  lifecycle {
    precondition {
      condition = alltrue([
        for name, p in local.platform.node_pools : (try(p.autoscaling, null) == null) == (try(p.power, null) == null)
      ])
      error_message = "node_pools: a pool needs both `autoscaling` and `power`, or neither."
    }
    precondition {
      condition = alltrue(flatten([
        for name, p in local.autoscaled_pools : [for n in keys(try(p.power.nodes, {})) : contains(try(p.nodes, []), n)]
      ]))
      error_message = "node_pools: `power.nodes` names a node that is not in the pool's `nodes`: ${jsonencode({ for name, p in local.autoscaled_pools : name => [for n in keys(try(p.power.nodes, {})) : n if !contains(try(p.nodes, []), n)] })}."
    }
    precondition {
      condition = alltrue([
        for name, p in local.autoscaled_pools : p.autoscaling.min >= 0 && p.autoscaling.min <= p.autoscaling.max && p.autoscaling.max <= length(keys(try(p.power.nodes, {})))
      ])
      error_message = "node_pools: autoscaling needs 0 <= min <= max <= number of `power.nodes`."
    }
    precondition {
      condition     = length(local.autoscaled_pools) == 0 || (length(local.cluster_autoscaler_vault_paths) == 1 && local.cluster_autoscaler_vault_path != "")
      error_message = "node_pools: every autoscaled pool needs the same non-empty `power.vault_path` (one plug password Secret)."
    }
    precondition {
      condition     = !contains(keys(local.autoscaled_pools), lookup(local.platform.services.cluster_autoscaler.node_selector, local.platform.node_pool_label, ""))
      error_message = "services.cluster_autoscaler.node_selector selects an autoscaled pool: the autoscaler could power off the node it runs on."
    }
  }
}

module "cluster_autoscaler" {
  source     = "./modules/cluster-autoscaler"
  depends_on = [module.addons, module.vault, terraform_data.cluster_autoscaler_checks]

  context         = module.platform_label.context
  enabled         = local.cluster_autoscaler_on
  namespace       = local.platform.services.cluster_autoscaler.namespace
  node_groups     = local.cluster_autoscaler_groups
  plug_username   = try(one(distinct([for p in values(local.autoscaled_pools) : try(p.power.username, "admin")])), "admin")
  vault_path      = local.cluster_autoscaler_vault_path
  vault_auth_role = local.platform.services.vault.enabled ? "vso-platform-plugpool" : ""
  node_selector   = local.platform.services.cluster_autoscaler.node_selector
  tolerations     = local.platform.services.cluster_autoscaler.tolerations
}
