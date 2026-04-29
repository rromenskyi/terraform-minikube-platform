# Unit tests for the cluster_role_rules knob on modules/component.
# Mocks both providers because every assertion here is plan-only —
# `terraform test` runs `terraform plan` against the module and
# inspects what *would* be created.

mock_provider "kubernetes" {}

# Variables that every run block has to satisfy — modules/component
# requires name + namespace + image + port unconditionally.
variables {
  name             = "platform-dash"
  namespace        = "phost-ipsupport-us-prod"
  image            = "ghcr.io/example/platform-dash:latest"
  port             = 3000
  volume_base_path = "/tmp/test-vol"
}

run "rbac_skipped_when_rules_empty" {
  command = plan

  variables {
    cluster_role_rules = []
  }

  assert {
    condition     = length(kubernetes_service_account_v1.this) == 0
    error_message = "ServiceAccount should not be created when cluster_role_rules is empty."
  }

  assert {
    condition     = length(kubernetes_cluster_role_v1.this) == 0
    error_message = "ClusterRole should not be created when cluster_role_rules is empty."
  }

  assert {
    condition     = length(kubernetes_cluster_role_binding_v1.this) == 0
    error_message = "ClusterRoleBinding should not be created when cluster_role_rules is empty."
  }
}

run "rbac_created_when_rules_present" {
  command = plan

  variables {
    cluster_role_rules = [
      {
        api_groups = [""]
        resources  = ["pods", "namespaces"]
        verbs      = ["get", "list", "watch"]
      },
      {
        api_groups = ["apps"]
        resources  = ["deployments"]
        verbs      = ["get", "list", "watch"]
      }
    ]
  }

  assert {
    condition     = length(kubernetes_service_account_v1.this) == 1
    error_message = "ServiceAccount should be created when cluster_role_rules is non-empty."
  }

  assert {
    condition     = kubernetes_service_account_v1.this["enabled"].metadata[0].name == "platform-dash"
    error_message = "ServiceAccount name should equal the component name."
  }

  assert {
    condition     = kubernetes_service_account_v1.this["enabled"].metadata[0].namespace == "phost-ipsupport-us-prod"
    error_message = "ServiceAccount should land in the component's namespace."
  }

  assert {
    condition     = length(kubernetes_cluster_role_v1.this) == 1
    error_message = "ClusterRole should be created when cluster_role_rules is non-empty."
  }

  assert {
    condition     = kubernetes_cluster_role_v1.this["enabled"].metadata[0].name == "phost-ipsupport-us-prod-platform-dash"
    error_message = "ClusterRole name should be `<namespace>-<component>` so it stays cluster-unique across operators sharing one cluster."
  }

  assert {
    condition     = length(kubernetes_cluster_role_v1.this["enabled"].rule) == 2
    error_message = "ClusterRole should carry one rule per item in var.cluster_role_rules."
  }

  assert {
    condition     = length(kubernetes_cluster_role_binding_v1.this) == 1
    error_message = "ClusterRoleBinding should be created when cluster_role_rules is non-empty."
  }

  assert {
    condition     = kubernetes_cluster_role_binding_v1.this["enabled"].metadata[0].name == "phost-ipsupport-us-prod-platform-dash"
    error_message = "ClusterRoleBinding name should match the ClusterRole name."
  }

  assert {
    condition     = kubernetes_cluster_role_binding_v1.this["enabled"].subject[0].name == "platform-dash"
    error_message = "ClusterRoleBinding subject should reference the SA by name."
  }

  assert {
    condition     = kubernetes_cluster_role_binding_v1.this["enabled"].subject[0].namespace == "phost-ipsupport-us-prod"
    error_message = "ClusterRoleBinding subject namespace should match the SA's namespace."
  }
}

run "deployment_uses_custom_sa_when_rbac_active" {
  command = plan

  variables {
    cluster_role_rules = [
      { api_groups = [""], resources = ["pods"], verbs = ["get"] }
    ]
  }

  assert {
    condition     = kubernetes_deployment_v1.this.spec[0].template[0].spec[0].service_account_name == "platform-dash"
    error_message = "Pod template should set service_account_name to the component's SA when cluster_role_rules is non-empty."
  }
}

# NOTE: a fourth assertion covering "service_account_name unset when
# cluster_role_rules is empty" was attempted but the kubernetes
# provider treats nullable string attributes as `(known after apply)`
# at plan time, so the condition can't resolve. The empty-rules case
# is already covered indirectly by `rbac_skipped_when_rules_empty`
# above (no SA resource exists, nothing to point at). Revisit if
# `override_during = plan` becomes ergonomic.
