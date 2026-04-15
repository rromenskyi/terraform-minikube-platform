variable "cluster_name" {
  description = "Kubernetes cluster context name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version to run inside the Minikube cluster"
  type        = string
  default     = "stable"
}

variable "letsencrypt_email" {
  description = "Email used for Let's Encrypt registration"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "cloudflare_tunnel_token" {
  description = "Cloudflare Tunnel Token"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Primary Cloudflare Zone ID used for tunnel DNS records"
  type        = string
}
