# Inputs of the cluster stack. The platform stack (the repository root) has
# its own `cluster_name`; keep both the same (`.env` sets TF_VAR_cluster_name
# for both).

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

variable "pod_cidr" {
  description = "Pod CIDR for the minikube distribution (Option A in main.tf). Unused by k3s."
  type        = string
  default     = "10.244.0.0/16"
}
