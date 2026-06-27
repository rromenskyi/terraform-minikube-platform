variable "context" {
  description = "Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module can chain its own label off the platform-wide context — tags propagate down, keeping every k8s resource the module emits consistent with the rest of the engine. Default `null` means the module produces a label with no inherited context."
  type        = string
  default     = null
}

variable "enabled" {
  description = "Deploy the Stalwart mail server. When false, no resources are created."
  type        = bool
  default     = true
}

variable "namespace" {
  description = "Namespace the mail Deployment lives in. Expected to exist already — created by root-level mail.tf alongside its ResourceQuota."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by the hostPath PV. Stalwart's data + config + bootstrap state land at <volume_base_path>/<namespace>/stalwart/. Survives ./tf bootstrap-k3s on purpose — losing this dir wipes mailboxes, DKIM keys, and the bootstrap admin record."
  type        = string
  default     = "/data/vol"
}

variable "image" {
  description = "Stalwart server container image. Repo changed from stalwartlabs/mail-server to stalwartlabs/stalwart at 0.16. Pin a specific tag — `latest` would silently pull schema changes between restarts."
  type        = string
  default     = "stalwartlabs/stalwart:v0.16.3"
}

variable "cli_url" {
  description = "URL of the stalwart-cli linux-x86_64 tarball. The CLI is a separate release from stalwartlabs/cli; not bundled in the server image. Init container downloads + extracts to a shared emptyDir."
  type        = string
  default     = "https://github.com/stalwartlabs/cli/releases/download/v1.0.4/stalwart-cli-x86_64-unknown-linux-musl.tar.xz"
}

variable "webui_url" {
  description = "URL of the upstream Stalwart WebUI bundle. Pinned to the version that ships with the server image — stale bundles drift the API contract. The init container downloads, sed-patches the OAuth client_id, repackages, and Stalwart's Application is pointed at the local file."
  type        = string
  default     = "https://github.com/stalwartlabs/webui/releases/download/v1.0.2/webui.zip"
}

variable "smtp_relay_listen_ip" {
  description = "Host IP the SMTP relay forwarder binds to. Specific by design — should be reachable from the public-relay tunnel only, NOT from the LAN, so this should be the WireGuard interface address (not 0.0.0.0). Required (no sane default — depends entirely on the operator's overlay topology)."
  type        = string
  default     = ""
}

variable "hostname" {
  description = "Public hostname Stalwart announces in SMTP banners and signs DKIM with. Should match the relay's reverse DNS — Gmail rejects mismatches. Required."
  type        = string
  default     = ""
}

variable "primary_domain" {
  description = "Default mail domain bootstrapped into Stalwart. Used as defaultDomainId on SystemSettings and as the domain Zitadel-OIDC users are auto-provisioned under. Required when the module is enabled."
  type        = string
  default     = ""
}

variable "additional_domains" {
  description = "Additional mail domains beyond the primary, declared by domain yamls that set `mail.submission_only: true`. Map of slug (e.g. `example-com`) → { name = <fqdn>, dkim_selector = <selector>, dmarc_policy = <none|quarantine|reject> }. Each entry causes engine to generate its own DKIM keypair and emit a Stalwart Domain + DkimSignature pair into the apply plan, so outgoing mail with `From:` matching an additional domain gets DKIM-signed with the right per-domain key. No accounts / mailboxes are auto-created — additional domains are submission-only out the door, no inbound or per-domain user provisioning. DNS records (MX/SPF/DKIM/DMARC) for each additional domain are emitted from the root mail.tf using this module's `additional_domain_dkim_dns` output."
  type = map(object({
    name          = string
    dkim_selector = optional(string, "stalwart")
    dmarc_policy  = optional(string, "none")
  }))
  default = {}
}

variable "zitadel_org_id" {
  description = "Zitadel organisation ID the OIDC application + role land in. Pulled from the parent module's data \"zitadel_orgs\" lookup."
  type        = string
  default     = ""
}

variable "zitadel_issuer_url" {
  description = "Zitadel public issuer URL (e.g. https://id.example.com). Used by Stalwart's OIDC directory to validate user-presented tokens via /userinfo. Empty string disables OIDC bootstrap (recovery-admin still works)."
  type        = string
  default     = ""
}

variable "zitadel_provider_authenticated" {
  description = "True when the root TF has been handed a non-empty TF_VAR_zitadel_pat for the Zitadel provider. False trips the precondition with a clear error instead of an opaque provider 'unauthenticated' on apply."
  type        = bool
  default     = false
}

variable "ingest_forwards" {
  description = "SMTP-push forwards keyed by a stable slug. Each entry adds a `redirect :copy` rule (every message whose SMTP envelope recipient matches ANY of `addresses` → a synthetic ingest address) into the combined DATA-stage Sieve script, and an MtaRoute pinning `synthetic_domain` to a plain-SMTP in-cluster listener at `smtp_host:smtp_port`. `addresses` lets one forward fan several tagged mailbox addresses (e.g. `mail@` for bounce VERP + `reply@` for reply-conversion) into the SAME listener — the consumer branches on the tagged local-part it reads from `X-Original-To`. Each address must resolve to a deliverable mailbox/alias (the `:copy` keeps the original locally). The copy never leaves the cluster and never hits MX/smarthost; a down listener means standard SMTP queue+retry. Coexists with the spam filter (left enabled). The applier triggers a settings reload when this is non-empty so the DATA-stage binding takes effect on the already-running server."
  type = map(object({
    addresses        = list(string)
    synthetic_domain = string
    smtp_host        = string
    smtp_port        = number
  }))
  default = {}
}

variable "smarthost_address" {
  description = "Hostname or IP of the outbound SMTP relay. Empty string keeps the default `mx` route (direct MX delivery); set to a relay address (typically the WireGuard IP of a public Postfix relay VPS, or its public hostname) to push every non-local message through it. Residential ISPs and Cloudflare Tunnel both block outbound :25 — without a smart host the queue spools forever and bounces. The relay must be configured to accept mail from this Stalwart's outgoing IP (typically by static IP / WG peer ACL) and to handle SPF/DKIM signing on the public side."
  type        = string
  default     = ""
}

variable "smarthost_port" {
  description = "Port of the outbound SMTP relay. 25 for plain SMTP relay over a trusted network (WireGuard), 465 for implicit TLS submission, 587 for STARTTLS submission with auth."
  type        = number
  default     = 25
}

variable "smarthost_implicit_tls" {
  description = "Use TLS for every connection to the smart host (port 465 style)."
  type        = bool
  default     = false
}

variable "smarthost_allow_invalid_certs" {
  description = "Skip TLS certificate validation when connecting to the smart host. Only flip on for relays presenting a self-signed cert on a trusted network — the public-relay VPS uses a real cert."
  type        = bool
  default     = false
}

variable "smarthost_username" {
  description = "Optional SMTP AUTH username for the smart host. Empty string skips AUTH (the relay must accept by source IP)."
  type        = string
  default     = ""
}

variable "smarthost_password" {
  description = "SMTP AUTH password matching `smarthost_username`. Sensitive — pass via TF_VAR_smarthost_password in `.env`. Ignored when `smarthost_username` is empty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_role_name" {
  description = "Name of the Zitadel project role that grants Stalwart admin access. The same string is also the name of the Stalwart Group whose membership carries the admin role — Zitadel emits `groups: [\"<role>\"]` in the id_token claim and the OIDC user auto-joins that group on login."
  type        = string
  default     = "mail-admin"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID of the primary mail domain. Module emits SPF/DKIM/DMARC TXT records directly into the zone — no manual yaml paste."
  type        = string
  default     = ""
}

variable "spf_authorized_ip" {
  description = "IPv4 (or `ip4:x ip4:y` chain) authorised to send mail for the primary domain. Should be the public IP of the relay every outbound message exits through. Empty string omits the SPF TXT record entirely — fine if SPF is published manually elsewhere."
  type        = string
  default     = ""
}

variable "dmarc_policy" {
  description = "DMARC policy directive. `quarantine` (move-to-spam on failure) for break-in; tighten to `reject` after a couple of weeks of clean aggregate reports."
  type        = string
  default     = "quarantine"
}

variable "internal_trusted_cidrs" {
  description = "CIDR ranges whose inbound SMTP connections are trusted and bypass the DATA-stage spam filter. Intended for in-cluster senders that deliver straight to Stalwart's :25 (e.g. Alertmanager → mail) — their mail comes from a pod IP, fails public SPF/DMARC, and would otherwise be scored as spam and filed to Junk. Empty list (default) leaves Stalwart's stock `enableSpamFilter` (filter every unauthenticated session) untouched, so this is a no-op unless an operator opts in."
  type        = list(string)
  default     = []
}

variable "dkim_selector" {
  description = "DKIM selector — the DNS label `<selector>._domainkey.<domain>` where the public key is published. Stable; rotating means generating a new key under a new selector and dual-signing through the cutover."
  type        = string
  default     = "stalwart"
}

variable "user_role_name" {
  description = "Name of the Zitadel project role that grants ordinary mailbox access. Required for any user who should be able to log into Roundcube — the Zitadel project gate (`project_role_check = true`) rejects users without a project-role, so absent this grant a Zitadel org member cannot reach the mail UI at all."
  type        = string
  default     = "mail-user"
}

variable "memory_request" {
  description = "Memory request for the Stalwart container. Idle Stalwart is ~50Mi; the request just keeps the kubelet from evicting under host pressure."
  type        = string
  default     = "128Mi"
}

variable "memory_limit" {
  description = "Memory limit for the Stalwart container. SQLite + a small mailbox set fits under 512Mi comfortably; bump if many tenants or large mailboxes show up."
  type        = string
  default     = "768Mi"
}

variable "cpu_request" {
  description = "CPU request for the Stalwart container. Idle is near-zero; this is the floor the scheduler reserves."
  type        = string
  default     = "50m"
}

variable "cpu_limit" {
  description = "CPU limit for the Stalwart container. Burst headroom for SMTP/JMAP spikes and DKIM signing — sustained usage is well below this."
  type        = string
  default     = "500m"
}

variable "node_selector" {
  description = "Node-selector applied to BOTH the main Stalwart Deployment and the smtp-relay sidecar Deployment. Two reasons both pods need pinning when this is set: (1) the main pod owns a hostPath PV under `volume_base_path/<namespace>/stalwart/data` and that data only lives on the original node — if the pod relocates, the new node has an empty dir; (2) the smtp-relay sidecar runs in hostNetwork mode and binds `smtp_relay_listen_ip` literally, so when that address exists on only one node the pod must land there or socat fails at start with 'Cannot assign requested address'. Empty = scheduler picks any node, fine for single-node clusters."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Taints both Stalwart pods tolerate. Empty list = pods cannot land on any tainted node. Applied to both the main Deployment and the smtp-relay sidecar Deployment so neither pod is evicted by node-level taint drains."
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}
