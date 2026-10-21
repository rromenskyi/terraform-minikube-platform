output "namespace" {
  description = "Namespace the file server lands in. Empty when the module is disabled."
  value       = var.enabled ? var.namespace : ""
}

output "address" {
  description = "Fixed LAN address of the file server — clients mount `smb://<address>/<share>`. Empty when disabled."
  value       = var.enabled ? var.load_balancer_ip : ""
}
