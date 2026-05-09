# Root null-label context.
#
# This is the keystone of every other label module instance in the
# engine. Downstream labels (per-project, per-resource) chain off the
# `context` output here so:
#   - tags added at this layer propagate to every k8s resource the
#     engine emits — operator can stamp `cost-center`, `region`,
#     `commit-sha`, etc. once and have them land on every Pod /
#     Service / Secret / IngressRoute on the cluster
#   - new modules wire up label naming with one line
#     (`context = var.context` + `module "X_label" { context =
#     var.context }`); no need to re-spell namespace / environment
#     / cluster_name in every module
#   - the engine's identifier scheme stays uniform — same label
#     module produces every name, same length-cap rules apply
#     uniformly
#
# `namespace = "platform"` because the engine itself is the
# "platform" tier. Tenant projects override `namespace` with their
# own k8s namespace (`phost-<slug>-<env>`) when chaining; the
# override wins per-key, parent fields the child doesn't override
# inherit.
#
# `name = var.cluster_name` so a kubectl filter like
# `kubectl get all -l app.kubernetes.io/instance=<cluster_name>`
# narrows to a specific cluster when the operator runs more than
# one (today: minikube vs k3s — tomorrow: per-region clusters).
module "platform_label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  namespace = "platform"
  name      = var.cluster_name
  tags = {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = "terraform-minikube-platform"
  }
}
