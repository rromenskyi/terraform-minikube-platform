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
  # NOTE: minikube's Flannel addon hardcodes "Network": "10.244.0.0/16" in its
  # kube-flannel-cfg ConfigMap and ignores kubeadm.pod-network-cidr. If this
  # variable is set to anything outside 10.244.0.0/16, Flannel crashes with
  # "subnet does not contain node PodCIDR" and all new pods get stuck in
  # ContainerCreating. Keep at 10.244.0.0/16 until the minikube provider
  # properly wires the Flannel net-conf from the pod_cidr input.
  # TODO: switch to "100.80.0.0/12" (CGNAT) once Flannel ConfigMap is patched
  # automatically during bootstrap.
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
  description = "Optional prefix for project namespaces (e.g. 'h-' → 'h-example-com-prod'). Empty by default."
  type        = string
  default     = ""
}

variable "host_volume_path" {
  description = "Parent path used verbatim by hostPath persistent volumes — set this to whatever the kubelet sees on the node. Native k3s / minikube --driver=none / any Linux bare-metal: use a regular host directory (default /data/vol). macOS Docker-driver minikube: use /minikube-host/Shared/vol (the in-VM mount of /Users/Shared/vol on the Mac)."
  type        = string
  default     = "/data/vol"
}

variable "minikube_node_ip" {
  # minikube with Docker driver on macOS always assigns 192.168.49.2 to the node.
  # Used to reach NodePort services (e.g. MySQL) from Terraform running on the host.
  description = "IP of the minikube cluster node (Docker driver default: 192.168.49.2)"
  type        = string
  default     = "192.168.49.2"
}
