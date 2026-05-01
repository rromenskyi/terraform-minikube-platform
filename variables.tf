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

variable "zitadel_pat" {
  description = <<-EOT
    Personal Access Token for the Zitadel TF provider. One-time
    bootstrap: log into the Zitadel console, Settings → Service
    Users → New, name it `tf-platform`, grant role `IAM_OWNER`,
    generate a PAT, paste here as `TF_VAR_zitadel_pat`. Empty when
    `services.zitadel.enabled = false` — the provider config in
    `zitadel.tf` no-ops in that case.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "zitadel_login_client_pat" {
  description = <<-EOT
    Personal Access Token for the Zitadel `login-client` machine
    user — read by the Login UI v2 sidecar to talk gRPC to the main
    Zitadel API. Created automatically at FIRSTINSTANCE and written
    to an emptyDir; that emptyDir is lost on every pod restart, so
    the Login UI hangs at "waiting for login-client.pat..." after
    any reboot. To unstick: paste the value here as
    `TF_VAR_zitadel_login_client_pat` once, TF mounts it via Secret
    at the path the sidecar expects, and restarts stop being
    destructive. Generate a fresh one with the tf-platform PAT:

      TF_PAT=$(kubectl get secret -n platform zitadel-tf-pat -o jsonpath='{.data.access_token}' | base64 -d)
      kubectl port-forward -n platform svc/zitadel 8080:8080 &
      USER_ID=$(curl -s -H "Authorization: Bearer $TF_PAT" -H 'Content-Type: application/json' \\
        -X POST 'http://localhost:8080/v2/users' \\
        -d '{"queries":[{"userNameQuery":{"userName":"login-client","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' \\
        | jq -r '.result[0].userId')
      curl -s -H "Authorization: Bearer $TF_PAT" -H 'Content-Type: application/json' \\
        -X POST "http://localhost:8080/management/v1/users/$USER_ID/pats" \\
        -d '{"expirationDate":"2099-12-31T00:00:00Z"}' | jq -r '.token'

    Empty when `services.zitadel.enabled = false`.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "smarthost_address" {
  description = "Hostname or IP of the outbound SMTP smart-host (relay) Stalwart sends every non-local message through. Empty disables relaying — direct MX delivery. Residential ISPs and Cloudflare Tunnel both block outbound :25, so a working relay is required for prod mail; the home cluster relays through a Postfix VPS at relay.ipsupport.us via the WireGuard overlay."
  type        = string
  default     = ""
}

variable "smarthost_port" {
  description = "Smart-host TCP port. 25 for plain SMTP relay over a trusted overlay (WireGuard), 465 for implicit TLS submission, 587 for STARTTLS submission with auth."
  type        = number
  default     = 25
}

variable "smarthost_implicit_tls" {
  description = "Use TLS for every connection to the smart host (port 465 style). False for plain :25 over a trusted overlay."
  type        = bool
  default     = false
}

variable "smarthost_allow_invalid_certs" {
  description = "Skip TLS certificate validation when connecting to the smart host. Only flip on for a relay presenting a self-signed cert on a trusted network."
  type        = bool
  default     = false
}

variable "smarthost_username" {
  description = "Optional SMTP AUTH username for the smart host. Empty skips AUTH (relay accepts by source IP)."
  type        = string
  default     = ""
}

variable "smarthost_password" {
  description = "SMTP AUTH password matching `smarthost_username`. Sensitive — supply via TF_VAR_smarthost_password in .env. Ignored when username is empty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "primary_mail_domain" {
  description = "Tenant domain that owns the platform's mail stack. Must match a `name:` in `config/domains/<x>.yaml` — its `cloudflare_zone_id` drives the SPF/DKIM/DMARC TXT records `modules/stalwart` emits, and `mail.<this>` is the WebUI hostname. Single-domain mail today; the variable lets you flip primary without code edits when a different tenant takes over mail."
  type        = string
  default     = "ipsupport.us"
}
