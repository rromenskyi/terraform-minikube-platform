# Plan-only tests of what the module renders. Both providers mocked.

mock_provider "kubernetes" {}
mock_provider "kubectl" {}

variables {
  enabled         = true
  vault_path      = "platform/power-plugs"
  vault_auth_role = "vso-platform-plugpool"
  node_groups = [{
    id       = "workers"
    min_size = 0
    max_size = 2
    template = { cpu = "24", memory = "60Gi", labels = { "example.com/pool" = "workers" } }
    nodes = [
      { name = "worker-1", plug_url = "http://plug-worker-1.example", plug_switch = "Relay" },
      { name = "worker-2", plug_url = "http://plug-worker-2.example", plug_switch = "Relay" },
    ]
  }]
}

run "disabled_creates_nothing" {
  command = plan
  variables {
    enabled = false
  }
  assert {
    condition     = length(kubernetes_deployment_v1.this) == 0 && length(kubernetes_namespace_v1.this) == 0
    error_message = "A disabled module must create nothing."
  }
}

run "plugpool_config_rendered" {
  command = plan
  assert {
    condition = (
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).listen == "127.0.0.1:8086" &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).providerIDPrefix == "k3s://" &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).powerOff.namespace == "cluster-autoscaler"
    )
    error_message = "plugpool listen / providerIDPrefix / powerOff.namespace wrong."
  }
  assert {
    condition = (
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).nodeGroups[0].id == "workers" &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).nodeGroups[0].maxSize == 2 &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).nodeGroups[0].template.labels["example.com/pool"] == "workers" &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).nodeGroups[0].nodes[1].plug.url == "http://plug-worker-2.example" &&
      yamldecode(kubernetes_config_map_v1.this["enabled"].data["plugpool.yaml"]).nodeGroups[0].nodes[1].plug["switch"] == "Relay"
    )
    error_message = "plugpool node group not rendered from node_groups."
  }
  assert {
    condition     = yamldecode(kubernetes_config_map_v1.this["enabled"].data["cloud-config.yaml"]).grpc_timeout == "15s"
    error_message = "cloud-config must raise grpc_timeout."
  }
}

run "ca_args_and_pod" {
  command = plan
  assert {
    condition = alltrue([for f in [
      "--cloud-provider=externalgrpc",
      "--cloud-config=/etc/plugpool/cloud-config.yaml",
      "--namespace=cluster-autoscaler",
      "--scale-down-unneeded-time=30m",
      "--scale-down-delay-after-add=30m",
      "--max-node-provision-time=10m",
      "--skip-nodes-with-system-pods=false",
      "--skip-nodes-with-local-storage=false",
    ] : contains(kubernetes_deployment_v1.this["enabled"].spec[0].template[0].spec[0].container[0].args, f)])
    error_message = "cluster-autoscaler flags missing."
  }
  assert {
    condition     = kubernetes_deployment_v1.this["enabled"].spec[0].template[0].metadata[0].annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"] == "false"
    error_message = "The autoscaler pod must not be evictable by itself."
  }
  assert {
    condition     = one([for e in kubernetes_deployment_v1.this["enabled"].spec[0].template[0].spec[0].container[1].env : e.value_from[0].secret_key_ref[0].name if e.name == "PLUGPOOL_PLUG_PASSWORD"]) == "plugpool-plugs"
    error_message = "plugpool must read the plug password from Secret plugpool-plugs."
  }
}

run "rbac" {
  command = plan
  assert {
    condition     = anytrue([for r in kubernetes_cluster_role_v1.this["enabled"].rule : contains(r.resources, "nodes") && contains(r.verbs, "delete")])
    error_message = "plugpool needs to delete Nodes."
  }
  assert {
    condition     = anytrue([for r in kubernetes_role_v1.this["enabled"].rule : contains(r.resources, "pods") && alltrue([for v in ["create", "list", "delete"] : contains(r.verbs, v)])])
    error_message = "plugpool needs pods create/list/delete in its namespace."
  }
}

run "shared_plug_rejected" {
  command = plan
  variables {
    node_groups = [{
      id       = "workers"
      min_size = 0
      max_size = 2
      template = { cpu = "24", memory = "60Gi" }
      nodes = [
        { name = "worker-1", plug_url = "http://plug-1.example", plug_switch = "Relay" },
        { name = "worker-2", plug_url = "http://plug-1.example", plug_switch = "Relay" },
      ]
    }]
  }
  expect_failures = [var.node_groups]
}

run "max_above_nodes_rejected" {
  command = plan
  variables {
    node_groups = [{
      id       = "workers"
      min_size = 0
      max_size = 3
      template = { cpu = "24", memory = "60Gi" }
      nodes    = [{ name = "worker-1", plug_url = "http://plug-1.example", plug_switch = "Relay" }]
    }]
  }
  expect_failures = [var.node_groups]
}
