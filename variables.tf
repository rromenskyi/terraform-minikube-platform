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

variable "distribution" {
  description = "Cluster distribution to bootstrap. `k3s` installs over SSH to `var.ssh_host` (production default). `minikube` runs locally via the docker-driver minikube (dev/experiment)."
  type        = string
  default     = "k3s"

  validation {
    condition     = contains(["minikube", "k3s"], var.distribution)
    error_message = "distribution must be \"minikube\" or \"k3s\"."
  }
}

variable "pod_cidr" {
  # NOTE: minikube's Flannel addon hardcodes "Network": "10.244.0.0/16" in its
  # kube-flannel-cfg ConfigMap and ignores kubeadm.pod-network-cidr. Anything
  # outside 10.244.0.0/16 causes Flannel to crash ("subnet does not contain
  # node PodCIDR") and leaves all pods stuck in ContainerCreating. The k3s
  # sibling does not have this limitation.
  description = "CIDR range to use for Pod IPs inside the Minikube cluster"
  type        = string
  default     = "10.244.0.0/16"
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

variable "namespace_prefix" {
  description = "Prefix prepended to every tenant-project namespace created from `config/domains/*.yaml` (e.g. `phost-` → `phost-example-com-prod`). Groups all project-tenant namespaces together under a common prefix in `kubectl get ns`, separate from the infra namespaces (`cert-manager`, `ingress-controller`, `monitoring`, `ops`, `platform`) that have their own fixed names. Set to `\"\"` to disable prefixing."
  type        = string
  default     = "phost-"
}

variable "host_volume_path" {
  description = "Parent path used verbatim by hostPath persistent volumes — set this to whatever the kubelet sees on the node. Native k3s / minikube --driver=none / any Linux bare-metal: use a regular host directory (default /data/vol). macOS Docker-driver minikube: use /minikube-host/Shared/vol (the in-VM mount of /Users/Shared/vol on the Mac)."
  type        = string
  default     = "/data/vol"
}
