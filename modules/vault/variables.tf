variable "enabled" {
  description = "Deploy Vault. When false, no resources are created."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace Vault lives in. Expected to exist already (typically `platform`)."
  type        = string
  default     = "platform"
}

variable "hostname" {
  description = "Public hostname Vault answers on (e.g. `vault.example.com`). Used for the IngressRoute Host(...) match (`config/components/vault.yaml` is `kind: external`, the operator's domain yaml supplies the route)."
  type        = string
  default     = ""
}

variable "image" {
  description = "Vault container image. Pin a specific tag — `:latest` would silently pull schema changes between restarts. `hashicorp/vault` is the upstream repo (community edition)."
  type        = string
  default     = "hashicorp/vault:1.18.4"
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PV. Vault's raft storage lands at `<volume_base_path>/<namespace>/vault/data/`. Survives `./tf bootstrap-k3s` on purpose — losing this dir wipes the secret store entirely."
  type        = string
  default     = "/data/vol"
}

variable "memory_request" {
  type    = string
  default = "256Mi"
}

variable "memory_limit" {
  type    = string
  default = "1Gi"
}

variable "cpu_request" {
  type    = string
  default = "100m"
}

variable "cpu_limit" {
  type    = string
  default = "1"
}
