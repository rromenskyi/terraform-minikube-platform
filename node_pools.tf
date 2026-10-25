# Node pools: every node belongs to one pool, carried as the label
# `<node_pool_label>=<pool>` (default `node-pool`), set on the node itself
# at registration by the operator's host tooling. Declared in
# config/platform.yaml:
#
#   node_pools:
#     storage: { nodes: [storage-1, storage-2] }
#     burst:   { nodes: [worker-1] }
#
# Workloads refer to pools instead of host names: a service with
# `node_pool: { preferred: [storage] }` gets a soft node affinity on the
# pool label. The plan fails when a registered node's label disagrees
# with its pool or a registered node is in no pool; a declared node that
# is not registered (e.g. powered off) is fine.

locals {
  # node name => pool name
  node_pool_of = merge([
    for pool, p in local.platform.node_pools : { for n in try(p.nodes, []) : n => pool }
  ]...)
  node_pool_declared = flatten([for pool, p in local.platform.node_pools : try(p.nodes, [])])

  # Services with `node_pool.preferred`: label => pools, for the modules'
  # preferred_node_affinity.
  node_pool_preference = {
    for svc in ["mysql", "seafile", "zitadel", "argocd"] :
    svc => (
      length(try(local.platform.services[svc].node_pool.preferred, [])) > 0
      ? { (local.platform.node_pool_label) = local.platform.services[svc].node_pool.preferred }
      : {}
    )
  }
}

data "kubernetes_nodes" "all" {
  for_each = length(local.platform.node_pools) > 0 ? toset(["enabled"]) : toset([])
}

resource "terraform_data" "node_pool_checks" {
  for_each = length(local.platform.node_pools) > 0 ? toset(["enabled"]) : toset([])

  lifecycle {
    precondition {
      condition     = length(local.node_pool_declared) == length(distinct(local.node_pool_declared))
      error_message = "node_pools: a node is listed in more than one pool."
    }
    precondition {
      condition = alltrue([
        for p in values(local.platform.services) : alltrue([
          for pool in try(p.node_pool.preferred, []) : contains(keys(local.platform.node_pools), pool)
        ])
      ])
      error_message = "node_pool.preferred names a pool that is not in node_pools."
    }
    precondition {
      condition = alltrue([
        for n in data.kubernetes_nodes.all["enabled"].nodes :
        try(n.metadata[0].labels[local.platform.node_pool_label], "") == lookup(local.node_pool_of, n.metadata[0].name, "")
        && lookup(local.node_pool_of, n.metadata[0].name, "") != ""
      ])
      error_message = "node_pools: registered nodes and their ${local.platform.node_pool_label} labels disagree with node_pools (or a node is in no pool): ${jsonencode({ for n in data.kubernetes_nodes.all["enabled"].nodes : n.metadata[0].name => { label = try(n.metadata[0].labels[local.platform.node_pool_label], ""), declared = lookup(local.node_pool_of, n.metadata[0].name, "") } if try(n.metadata[0].labels[local.platform.node_pool_label], "") != lookup(local.node_pool_of, n.metadata[0].name, "") || lookup(local.node_pool_of, n.metadata[0].name, "") == "" })}."
    }
  }
}
