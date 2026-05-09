output "endpoint" {
  description = "In-cluster BuildKit gRPC endpoint for `docker buildx create --driver remote --endpoint <this>`. Empty when the module is disabled."
  value = (
    var.enabled
    ? "tcp://${kubernetes_service_v1.this["enabled"].metadata[0].name}.${kubernetes_namespace_v1.this["enabled"].metadata[0].name}.svc.cluster.local:1234"
    : ""
  )
}
