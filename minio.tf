# MinIO — S3-compatible object store.
#
# Two topologies, operator-selected via `services.minio.distributed.enabled`:
#   - standalone (default): single-replica Deployment + one PVC.
#   - distributed (4+ replicas): StatefulSet + per-replica PVC,
#     erasure-coded across the pool. Required minimum 4 disks.
#
# Either way, operator declares buckets via `services.minio.buckets` —
# engine pre-creates each, generates a dedicated access-key pair, and
# emits a `kubernetes_secret_v1` carrying the standard `S3_*` env names
# in the consumer namespace. Consumer chart `envFrom`s the Secret
# and points its S3 client at the in-cluster Service endpoint.

module "minio" {
  source     = "./modules/minio"
  depends_on = [module.addons]

  enabled       = local.platform.services.minio.enabled
  namespace     = kubernetes_namespace_v1.platform.metadata[0].name
  storage_class = local.platform.services.minio.storage_class
  storage_size  = local.platform.services.minio.storage_size
  node_selector = local.platform.services.minio.node_selector
  tolerations   = local.platform.services.minio.tolerations
  distributed   = local.platform.services.minio.distributed
  buckets       = local.platform.services.minio.buckets
}

output "minio_endpoint" {
  description = "Cluster-internal MinIO API URL. Empty when MinIO is disabled."
  value       = module.minio.endpoint
}

output "minio_buckets" {
  description = "Map of bucket name → consumer-namespace Secret name. Empty when MinIO is disabled or no buckets are configured."
  value       = module.minio.bucket_secret_names
}
