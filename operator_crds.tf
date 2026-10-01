# CRDs of operator charts whose CRDs live in the chart's `crds/` folder.
#
# Helm installs those once and never upgrades them, so a chart bump alone
# leaves the operator running against the CRDs of the first install. The
# CRDs are rendered here from the same chart versions the modules deploy
# and handed to each module, which server-side applies them.
#
# They are rendered at the root rather than inside the modules: a data
# source in a module that carries a module-level `depends_on` is deferred
# to apply whenever that dependency has pending changes, which leaves the
# CRD for_each keys unknown at plan.

data "helm_template" "vault_config_operator_crds" {
  for_each = local.platform.services.vault.enabled ? toset(["enabled"]) : toset([])

  name         = "vault-config-operator"
  repository   = "https://redhat-cop.github.io/vault-config-operator"
  chart        = "vault-config-operator"
  version      = local.platform.services.vault.vault_config_operator_chart_version
  include_crds = true
}

data "helm_template" "arc_controller_crds" {
  for_each = local.platform.services.github_runners.enabled ? toset(["enabled"]) : toset([])

  name         = "arc-controller"
  repository   = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart        = "gha-runner-scale-set-controller"
  version      = local.platform.services.github_runners.chart_version
  include_crds = true
}

data "helm_template" "trivy_operator_crds" {
  for_each = local.platform.services.security_scan.enabled ? toset(["enabled"]) : toset([])

  name         = "trivy-operator"
  repository   = "https://aquasecurity.github.io/helm-charts/"
  chart        = "trivy-operator"
  version      = local.platform.services.security_scan.trivy_operator_chart_version
  include_crds = true
}
