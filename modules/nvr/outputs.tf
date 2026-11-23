output "namespace" {
  description = "Namespace of the NVR (null when disabled)."
  value       = var.enabled ? kubernetes_namespace_v1.this["enabled"].metadata[0].name : null
}

output "service_name" {
  description = "Service of Frigate: port 5000 (UI/API without Frigate's own login; gate it), 8554 (RTSP restream), 8555 (WebRTC)."
  value       = var.enabled ? kubernetes_service_v1.this["enabled"].metadata[0].name : null
}
