output "device_class_name" {
  description = "DeviceClass pods claim VRAM from (empty when disabled)."
  value       = var.enabled ? var.driver_name : ""
}
