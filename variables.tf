variable "cluster_name" {
  description = "Kubernetes cluster context name"
  type        = string
  default     = "minikube"
}

variable "memory" {
  description = "Memory allocated to the Minikube cluster in MB"
  type        = number
  default     = 4096
}

variable "kubernetes_version" {
  description = "Kubernetes version to run inside the cluster. For minikube use `stable` or a `v1.x.y` tag. For k3s pin a build like `v1.31.4+k3s1`, or leave this alone because the k3s block does not pass it."
  type        = string
  default     = "v1.34.4"
}

variable "pod_cidr" {
  description = "CIDR range to use for Pod IPs inside the Minikube cluster"
  type        = string
  default     = "100.80.0.0/12"
}

# ---------------------------------------------------------------------------
# SSH connection to the k3s target host (only used when the k3s distribution
# block is active in main.tf). Defaults cover the local loopback install;
# ssh_user and ssh_private_key_path have no sane defaults and must be set.
# ---------------------------------------------------------------------------

variable "ssh_host" {
  description = "Host where k3s will be installed. `127.0.0.1` for a local install."
  type        = string
  default     = "127.0.0.1"
}

variable "ssh_port" {
  description = "SSH port on the k3s target host"
  type        = number
  default     = 22
}

variable "ssh_user" {
  description = "SSH user with passwordless sudo on the k3s target host. Required only when the k3s distribution is active."
  type        = string
  default     = ""
}

variable "ssh_private_key_path" {
  description = "Path to the SSH private key used to authenticate against the k3s target host. Required only when the k3s distribution is active."
  type        = string
  default     = ""
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

variable "cloudflare_tunnel_secret" {
  description = "Arbitrary secret used when creating the Cloudflare Tunnel (base64-encoded by Terraform). Not the same as the JWT token cloudflared uses to connect."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Primary Cloudflare Zone ID used for tunnel DNS records"
  type        = string
}

variable "cloudflare_tunnel_domain" {
  description = "Apex domain used to build tunnel ingress hostnames (e.g. setting `example.com` produces `echo.example.com`, `grafana.example.com`, ...). Must match the Cloudflare zone referenced by `cloudflare_zone_id`. Required — set via TF_VAR_cloudflare_tunnel_domain in `.env`."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.cloudflare_tunnel_domain))
    error_message = "cloudflare_tunnel_domain must be a valid DNS label sequence (lowercase alphanumerics, dots, hyphens)."
  }
}
