output "storage_classes" {
  description = "Names of the StorageClasses created."
  value       = [for sc in var.storage_classes : sc.name if var.enabled]
}
