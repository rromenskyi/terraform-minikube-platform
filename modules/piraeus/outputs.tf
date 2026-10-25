output "storage_classes" {
  description = "Names of the StorageClasses created."
  value       = [for sc in var.storage_classes : sc.name if var.enabled]
}

output "volume_preferred_node_selectors" {
  description = "StorageClass name => node selectors of its storage pool's entries (`storage_pools[].node_selector`): the nodes that hold copies of its volumes. Pods with volumes on the class should prefer them, so their data is a local copy. Empty when disabled."
  value = {
    for sc in var.storage_classes : sc.name => [
      for p in var.storage_pools : p.node_selector if p.name == sc.storage_pool && length(p.node_selector) > 0
    ] if var.enabled
  }
}

output "volume_node_labels" {
  description = "StorageClass name => `linbit.com/hostname`, the label the LINSTOR CSI node plugin puts on the nodes it runs on. Pods with volumes on these classes should require it (`Exists`): elsewhere the volume cannot attach. Empty when disabled."
  value       = { for sc in var.storage_classes : sc.name => "linbit.com/hostname" if var.enabled }
}
