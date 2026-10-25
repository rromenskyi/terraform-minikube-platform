# Unit tests for where the build cache lives (hostPath vs PVC) and the
# node affinity that comes with it. Plan-only, both providers mocked.

mock_provider "kubernetes" {}
mock_provider "kubectl" {}

variables {
  enabled = true
}

run "hostpath_cache_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_persistent_volume_claim_v1.cache) == 0
    error_message = "No cache PVC without storage_class."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.volumes[0].hostPath.path == "/data/vol/buildkit-cache"
    error_message = "The cache must be the host_path hostPath without storage_class."
  }

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec), "affinity")
    error_message = "No affinity without storage_class or preferred_node_affinity."
  }
}

run "pvc_cache_with_storage_class" {
  command = plan

  variables {
    storage_class           = "replicated"
    storage_size            = "150Gi"
    volume_node_label       = "linbit.com/hostname"
    preferred_node_affinity = { "node-pool" = ["storage"] }
  }

  assert {
    condition     = kubernetes_persistent_volume_claim_v1.cache["replicated"].spec[0].storage_class_name == "replicated"
    error_message = "The cache PVC must use storage_class."
  }

  assert {
    condition     = kubernetes_persistent_volume_claim_v1.cache["replicated"].spec[0].resources[0].requests.storage == "150Gi"
    error_message = "The cache PVC must request storage_size."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.volumes[0].persistentVolumeClaim.claimName == "buildkitd-cache-replicated"
    error_message = "The cache volume must be the PVC, named after its class (a class change then adds a new claim instead of replacing one the Pod still holds)."
  }

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.volumes[0]), "hostPath")
    error_message = "No hostPath with storage_class."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0] == { key = "linbit.com/hostname", operator = "Exists" }
    error_message = "The Pod must require the CSI node label."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0] == { key = "node-pool", operator = "In", values = ["storage"] }
    error_message = "The Pod must prefer the preferred_node_affinity nodes."
  }
}

run "preference_without_pvc" {
  command = plan

  variables {
    volume_node_label       = "linbit.com/hostname"
    preferred_node_affinity = { "node-pool" = ["storage"] }
  }

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.affinity.nodeAffinity), "requiredDuringSchedulingIgnoredDuringExecution")
    error_message = "volume_node_label applies only to a PVC cache."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.this["enabled"].yaml_body).spec.template.spec.affinity.nodeAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].preference.matchExpressions[0] == { key = "node-pool", operator = "In", values = ["storage"] }
    error_message = "preferred_node_affinity applies with a hostPath cache too."
  }
}
