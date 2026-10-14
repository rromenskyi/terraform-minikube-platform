variable "cluster_name" {
  description = "Kubernetes cluster context name"
  type        = string
  default     = "minikube"
}

variable "github_runner_tokens" {
  description = "Sensitive map of GitHub PATs keyed by `services.github_runners.scale_sets` map key. When a key is present here AND the matching scale-set entry leaves `github_secret_name` empty, the engine emits a `<key>-github-pat` Secret in the scale-set's namespace carrying `github_token: <value>` and wires the chart to consume it. Operator pastes via `TF_VAR_github_runner_tokens='{\"<key>\":\"ghp_...\"}'` in the gitignored `.env` (BWS migration on the ops backlog). Empty map (default) implies every scale set must reference an externally-managed `github_secret_name`."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "cluster_distribution" {
  description = "Distribution of the cluster (`k3s` or `minikube`), the cluster stack's `cluster_distribution` output. The add-ons pick storage class and Traefik service type by it."
  type        = string
  default     = "k3s"

  validation {
    condition     = contains(["k3s", "minikube"], var.cluster_distribution)
    error_message = "cluster_distribution must be k3s or minikube."
  }
}

variable "kubeconfig_path" {
  description = "Kubeconfig of the cluster. Empty: the file the cluster stack's k3s module writes, `cluster/.terraform/k3s-<cluster_name>.kubeconfig`. Set it for minikube, or in CI."
  type        = string
  default     = ""
}

variable "kube_context" {
  description = "Context in `kubeconfig_path` for the root providers. Empty: the file's current context. The add-ons module (terraform-k8s-addons) always uses the file's current context, so when they differ the add-ons land elsewhere: set current-context to this context too."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Email used for Let's Encrypt registration"
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Same value the wrapper exports as `CLOUDFLARE_API_TOKEN` for the provider — declared as a TF var here so we can also materialise it into a `kubernetes_secret_v1` for cert-manager's DNS-01 ACME solver to read. The provider itself still picks the token up from the env var directly (see `_providers.tf`); this declaration is *only* used for the cert-manager Secret. State holds the value (sensitive); the trade-off vs. provider-only env-pickup is acceptable because the same token value already flows into Vault-managed CF tunnel records via `cloudflare_dns_record` resources whose state holds the records themselves."
  type        = string
  sensitive   = true
  default     = ""
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

variable "monitoring_scrape_passwords" {
  description = "HTTP basic-auth passwords for `monitoring.external_targets`, keyed by target name (the name in the config). Set in the gitignored terraform.tfvars; the engine stores each in a Secret in `monitoring`."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "operator_secret_values" {
  description = <<-EOT
    Operator-supplied literal values for entries declared under a project's
    `secrets:` map in the domain yaml. Outer key matches a `secrets:` entry
    name (e.g. an external-storage credentials Secret); inner map carries the
    literal data the engine writes into the resulting `kubernetes_secret_v1`.
    When an outer key is present here, every key listed under that entry's
    `secrets.<name>.keys:` in the yaml MUST be present in the inner map —
    plan-time check rejects partial coverage with a clear error. When an
    outer key is absent, the engine falls back to the historical random-shared
    behavior (one `random_password` shared across every listed key in the
    yaml). Use this for credentials the engine cannot synthesize: third-party
    storage / OIDC client / vendor API keys. Never commit values to the
    public repo — the live `terraform.tfvars` is gitignored.
  EOT
  type        = map(map(string))
  default     = {}
  sensitive   = true
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

# Mail-stack tenant settings (smarthost target/port/auth-mode, WG bind
# IP, public IP for SPF, DKIM selector, DMARC policy, and which domain
# owns the stack) live under `mail:` in the primary domain's yaml —
# see `config/domains/example.com.yaml.example`. Domain yamls are
# gitignored, so tenant-specific values stay out of the repo. The only
# bit that doesn't fit yaml is the SMTP-AUTH password (when relaying
# through an AUTH-required SaaS like Mailgun); operators on that path
# can re-add a sensitive `smarthost_password` variable here and pipe
# it through `mail.tf`. A relay that authorizes by source network or
# tunnel peer needs no AUTH, and then the var is unused.
