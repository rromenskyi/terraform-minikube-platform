output "kubeconfig_path" {
  description = "Absolute path of the cluster's admin kubeconfig. The platform stack reads it from `TF_VAR_kubeconfig_path`, or from the k3s default under `cluster/.terraform/` when unset."
  value       = abspath(module.k8s.kubeconfig_path)
}

output "cluster_name" {
  value = module.k8s.cluster_name
}

output "cluster_distribution" {
  description = "Set the platform stack's `cluster_distribution` to this value."
  value       = module.k8s.cluster_distribution
}
