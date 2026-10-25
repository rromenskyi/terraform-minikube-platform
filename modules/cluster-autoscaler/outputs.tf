output "namespace" {
  description = "Namespace of cluster-autoscaler, plugpool and the poweroff pods; empty when disabled."
  value       = one([for n in kubernetes_namespace_v1.this : n.metadata[0].name])
}
