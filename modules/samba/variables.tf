variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module chains its own label off the platform-wide context. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Whether to deploy the Samba file server. False collapses every resource."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace of the file server."
  type        = string
  default     = "nas"
}

variable "image" {
  description = "Samba image (ServerContainers, configured by environment variables; macOS `fruit` defaults built in). Pin a tag or digest."
  type        = string
  default     = "ghcr.io/servercontainers/samba:a3.24.2-s4.23.8-r0"
}

variable "storage_class" {
  description = "StorageClass of the shares' volume. Use a replicated class (e.g. a 2-copy LINSTOR class) so the file server survives one storage node being down: the pod then starts on another node with the volume."
  type        = string
  default     = ""
}

variable "size" {
  description = "Size of the shares' volume. Can be raised later (online expansion, if the StorageClass allows it)."
  type        = string
  default     = "100Gi"
}

variable "node_hostnames" {
  description = "Nodes the file server may run on (`kubernetes.io/hostname`), a required node affinity. With a 2-copy volume, list the nodes holding the copies. The address pool must announce from the same nodes (the Service keeps the clients' source address, `externalTrafficPolicy: Local`)."
  type        = list(string)
  default     = []
}

variable "load_balancer_ip" {
  description = "Fixed LAN address of the file server (a MetalLB L2 address). Clients mount `smb://<address>/<share>`."
  type        = string
  default     = ""
}

variable "address_pool" {
  description = "MetalLB address pool `load_balancer_ip` comes from."
  type        = string
  default     = ""
}

variable "allowed_networks" {
  description = "Client networks Samba accepts (`hosts allow`); everything else is denied. The Service keeps client source addresses, so these are the real LAN addresses."
  type        = list(string)
  default     = []
}

variable "users" {
  description = "Samba accounts: username => { uid }. The uid owns the files (match the owner of migrated data). Passwords come from Vault (`vault_path`, one key per username)."
  type = map(object({
    uid = number
  }))
  default = {}
}

variable "vault_path" {
  description = "KV-v2 path under the `secret` mount (e.g. `platform/samba/accounts`) holding one key per username in `users`, value = that user's password. Synced into the namespace by Vault Secrets Operator; a password change restarts the server."
  type        = string
  default     = "platform/samba/accounts"
}

variable "shares" {
  description = "Shares, each a directory `/shares/<name>` on the volume: name, read_only (default false), valid_users (default: every account)."
  type = list(object({
    name        = string
    read_only   = optional(bool, false)
    valid_users = optional(list(string), [])
  }))
  default = []
}

variable "seed" {
  description = <<-EOT
    Copy existing data in before the server starts: a directory on one node
    whose subdirectories are the shares (`<host_path>/<share>`). An init
    container runs `rsync -aHAX --delete` (keeps owners, ACLs, extended
    attributes = macOS metadata, hard links) from it into the volume on every
    start while this is set, and the pod is pinned to `node` meanwhile. The
    first run copies everything; a restart only copies the changes. While set,
    the volume mirrors the old data: make the old shares read-only before the
    last run, and clear this (null) before writing to the new server.
  EOT
  type = object({
    node      = string
    host_path = string
  })
  default = null
}

variable "seed_image" {
  description = "Image with rsync for the seed init container."
  type        = string
  default     = "instrumentisto/rsync-ssh:alpine3.23-r3"
}

variable "resources" {
  description = "Resources of the Samba container."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { cpu = "2", memory = "2Gi" }
  }
}

variable "failover_seconds" {
  description = "How long the pod stays bound to a node that is not ready or unreachable before Kubernetes moves it (tolerationSeconds). Default 300 in Kubernetes; lower = faster failover after a node crash."
  type        = number
  default     = 30
}
