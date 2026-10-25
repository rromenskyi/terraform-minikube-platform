# Unit tests for the node affinity derived from where the component's
# volume lives: required `<volume_node_label> Exists`, preferred nodes of
# `volume_preferred_node_selectors`. Plan-only, provider mocked.

mock_provider "kubernetes" {}

variables {
  name             = "site"
  namespace        = "phost-example-com-prod"
  image            = "nginx:alpine"
  port             = 80
  volume_base_path = "/tmp/test-vol"
  storage          = [{ mount = "/data", size = "1Gi" }]
}

run "locality_preference_with_storage_class" {
  command = plan

  variables {
    storage_class                   = "replicated"
    volume_node_label               = "linbit.com/hostname"
    volume_preferred_node_selectors = [{ "node-pool" = "storage" }]
  }

  assert {
    condition     = kubernetes_deployment_v1.this.spec[0].template[0].spec[0].affinity[0].node_affinity[0].preferred_during_scheduling_ignored_during_execution[0].preference[0].match_expressions[0].key == "node-pool" && kubernetes_deployment_v1.this.spec[0].template[0].spec[0].affinity[0].node_affinity[0].preferred_during_scheduling_ignored_during_execution[0].preference[0].match_expressions[0].values == toset(["storage"])
    error_message = "The pod must prefer the nodes holding its volume's copies."
  }

  assert {
    condition     = kubernetes_deployment_v1.this.spec[0].template[0].spec[0].affinity[0].node_affinity[0].required_during_scheduling_ignored_during_execution[0].node_selector_term[0].match_expressions[0].key == "linbit.com/hostname"
    error_message = "The volume attach requirement must stay."
  }
}

run "locality_preference_keeps_own_preferences" {
  command = plan

  variables {
    storage_class                   = "replicated"
    volume_preferred_node_selectors = [{ "node-pool" = "storage" }]
    affinity = {
      node_affinity = {
        preferred_during_scheduling_ignored_during_execution = [{
          weight     = 10
          preference = { match_expressions = [{ key = "gpu", operator = "In", values = ["intel"] }] }
        }]
      }
    }
  }

  assert {
    condition     = length(kubernetes_deployment_v1.this.spec[0].template[0].spec[0].affinity[0].node_affinity[0].preferred_during_scheduling_ignored_during_execution) == 2
    error_message = "The component's own preferred terms and the locality term must both be kept."
  }
}

run "no_locality_preference_without_storage_class" {
  command = plan

  variables {
    volume_preferred_node_selectors = [{ "node-pool" = "storage" }]
  }

  assert {
    condition     = length(kubernetes_deployment_v1.this.spec[0].template[0].spec[0].affinity) == 0
    error_message = "Host-path volumes get no locality preference."
  }
}
