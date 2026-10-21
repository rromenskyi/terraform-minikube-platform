output "storage_classes" {
  description = "Names of the StorageClasses created."
  value       = [for sc in var.storage_classes : sc.name if var.enabled]
}

output "volume_node_labels" {
  description = "StorageClass name => `linbit.com/hostname`, the label the LINSTOR CSI node plugin puts on the nodes it runs on. Pods with volumes on these classes should require it (`Exists`): elsewhere the volume cannot attach. Empty when disabled."
  value       = { for sc in var.storage_classes : sc.name => "linbit.com/hostname" if var.enabled }
}
