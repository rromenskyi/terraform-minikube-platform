# stalwart

Stalwart mail server (SMTP + IMAP + JMAP) StatefulSet, plus relay Deployment, ingress routes, DNS records, and Zitadel app for OIDC.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_cloudflare"></a> [cloudflare](#requirement\_cloudflare) | ~> 5.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |
| <a name="requirement_zitadel"></a> [zitadel](#requirement\_zitadel) | ~> 2.9 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_cloudflare"></a> [cloudflare](#provider\_cloudflare) | ~> 5.0 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.0 |
| <a name="provider_tls"></a> [tls](#provider\_tls) | ~> 4.0 |
| <a name="provider_zitadel"></a> [zitadel](#provider\_zitadel) | ~> 2.9 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [cloudflare_dns_record.dkim](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_dns_record.dmarc](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [cloudflare_dns_record.spf](https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/dns_record) | resource |
| [kubectl_manifest.stalwart_account_ingressroute](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.stalwart_admin_ingressroute](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_deployment_v1.stalwart](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_deployment_v1.stalwart_smtp_relay](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.stalwart](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.stalwart](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_secret_v1.recovery_admin](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_secret_v1.stalwart_seed](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [kubernetes_service_v1.stalwart_http](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [kubernetes_service_v1.stalwart_smtp](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [random_password.admin_path](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [random_password.recovery_admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [tls_private_key.dkim](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/resources/private_key) | resource |
| [zitadel_application_oidc.stalwart](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/application_oidc) | resource |
| [zitadel_project.stalwart](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project) | resource |
| [zitadel_project_role.admin](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project_role) | resource |
| [zitadel_project_role.user](https://registry.terraform.io/providers/zitadel/zitadel/latest/docs/resources/project_role) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_admin_role_name"></a> [admin\_role\_name](#input\_admin\_role\_name) | Name of the Zitadel project role that grants Stalwart admin access. The same string is also the name of the Stalwart Group whose membership carries the admin role — Zitadel emits `groups: ["<role>"]` in the id\_token claim and the OIDC user auto-joins that group on login. | `string` | `"mail-admin"` | no |
| <a name="input_cli_url"></a> [cli\_url](#input\_cli\_url) | URL of the stalwart-cli linux-x86\_64 tarball. The CLI is a separate release from stalwartlabs/cli; not bundled in the server image. Init container downloads + extracts to a shared emptyDir. | `string` | `"https://github.com/stalwartlabs/cli/releases/download/v1.0.4/stalwart-cli-x86_64-unknown-linux-musl.tar.xz"` | no |
| <a name="input_cloudflare_zone_id"></a> [cloudflare\_zone\_id](#input\_cloudflare\_zone\_id) | Cloudflare zone ID of the primary mail domain. Module emits SPF/DKIM/DMARC TXT records directly into the zone — no manual yaml paste. | `string` | `""` | no |
| <a name="input_cpu_limit"></a> [cpu\_limit](#input\_cpu\_limit) | CPU limit for the Stalwart container. Burst headroom for SMTP/JMAP spikes and DKIM signing — sustained usage is well below this. | `string` | `"500m"` | no |
| <a name="input_cpu_request"></a> [cpu\_request](#input\_cpu\_request) | CPU request for the Stalwart container. Idle is near-zero; this is the floor the scheduler reserves. | `string` | `"50m"` | no |
| <a name="input_dkim_selector"></a> [dkim\_selector](#input\_dkim\_selector) | DKIM selector — the DNS label `<selector>._domainkey.<domain>` where the public key is published. Stable; rotating means generating a new key under a new selector and dual-signing through the cutover. | `string` | `"stalwart"` | no |
| <a name="input_dmarc_policy"></a> [dmarc\_policy](#input\_dmarc\_policy) | DMARC policy directive. `quarantine` (move-to-spam on failure) for break-in; tighten to `reject` after a couple of weeks of clean aggregate reports. | `string` | `"quarantine"` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Deploy the Stalwart mail server. When false, no resources are created. | `bool` | `true` | no |
| <a name="input_hostname"></a> [hostname](#input\_hostname) | Public hostname Stalwart announces in SMTP banners and signs DKIM with. Should match the relay's reverse DNS — Gmail rejects mismatches. Required. | `string` | `""` | no |
| <a name="input_image"></a> [image](#input\_image) | Stalwart server container image. Repo changed from stalwartlabs/mail-server to stalwartlabs/stalwart at 0.16. Pin a specific tag — `latest` would silently pull schema changes between restarts. | `string` | `"stalwartlabs/stalwart:v0.16.3"` | no |
| <a name="input_memory_limit"></a> [memory\_limit](#input\_memory\_limit) | Memory limit for the Stalwart container. SQLite + a small mailbox set fits under 512Mi comfortably; bump if many tenants or large mailboxes show up. | `string` | `"768Mi"` | no |
| <a name="input_memory_request"></a> [memory\_request](#input\_memory\_request) | Memory request for the Stalwart container. Idle Stalwart is ~50Mi; the request just keeps the kubelet from evicting under host pressure. | `string` | `"128Mi"` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace the mail Deployment lives in. Expected to exist already — created by root-level mail.tf alongside its ResourceQuota. | `string` | `null` | no |
| <a name="input_node_selector"></a> [node\_selector](#input\_node\_selector) | Node-selector applied to BOTH the main Stalwart Deployment and the smtp-relay sidecar Deployment. Two reasons both pods need pinning when this is set: (1) the main pod owns a hostPath PV under `volume_base_path/<namespace>/stalwart/data` and that data only lives on the original node — if the pod relocates, the new node has an empty dir; (2) the smtp-relay sidecar runs in hostNetwork mode and binds `smtp_relay_listen_ip` literally, so when that address exists on only one node the pod must land there or socat fails at start with 'Cannot assign requested address'. Empty = scheduler picks any node, fine for single-node clusters. | `map(string)` | `{}` | no |
| <a name="input_primary_domain"></a> [primary\_domain](#input\_primary\_domain) | Default mail domain bootstrapped into Stalwart. Used as defaultDomainId on SystemSettings and as the domain Zitadel-OIDC users are auto-provisioned under. Required when the module is enabled. | `string` | `""` | no |
| <a name="input_smarthost_address"></a> [smarthost\_address](#input\_smarthost\_address) | Hostname or IP of the outbound SMTP relay. Empty string keeps the default `mx` route (direct MX delivery); set to a relay address (typically the WireGuard IP of a public Postfix relay VPS, or its public hostname) to push every non-local message through it. Residential ISPs and Cloudflare Tunnel both block outbound :25 — without a smart host the queue spools forever and bounces. The relay must be configured to accept mail from this Stalwart's outgoing IP (typically by static IP / WG peer ACL) and to handle SPF/DKIM signing on the public side. | `string` | `""` | no |
| <a name="input_smarthost_allow_invalid_certs"></a> [smarthost\_allow\_invalid\_certs](#input\_smarthost\_allow\_invalid\_certs) | Skip TLS certificate validation when connecting to the smart host. Only flip on for relays presenting a self-signed cert on a trusted network — the public-relay VPS uses a real cert. | `bool` | `false` | no |
| <a name="input_smarthost_implicit_tls"></a> [smarthost\_implicit\_tls](#input\_smarthost\_implicit\_tls) | Use TLS for every connection to the smart host (port 465 style). | `bool` | `false` | no |
| <a name="input_smarthost_password"></a> [smarthost\_password](#input\_smarthost\_password) | SMTP AUTH password matching `smarthost_username`. Sensitive — pass via TF\_VAR\_smarthost\_password in `.env`. Ignored when `smarthost_username` is empty. | `string` | `""` | no |
| <a name="input_smarthost_port"></a> [smarthost\_port](#input\_smarthost\_port) | Port of the outbound SMTP relay. 25 for plain SMTP relay over a trusted network (WireGuard), 465 for implicit TLS submission, 587 for STARTTLS submission with auth. | `number` | `25` | no |
| <a name="input_smarthost_username"></a> [smarthost\_username](#input\_smarthost\_username) | Optional SMTP AUTH username for the smart host. Empty string skips AUTH (the relay must accept by source IP). | `string` | `""` | no |
| <a name="input_smtp_relay_listen_ip"></a> [smtp\_relay\_listen\_ip](#input\_smtp\_relay\_listen\_ip) | Host IP the SMTP relay forwarder binds to. Specific by design — should be reachable from the public-relay tunnel only, NOT from the LAN, so this should be the WireGuard interface address (not 0.0.0.0). Required (no sane default — depends entirely on the operator's overlay topology). | `string` | `""` | no |
| <a name="input_spf_authorized_ip"></a> [spf\_authorized\_ip](#input\_spf\_authorized\_ip) | IPv4 (or `ip4:x ip4:y` chain) authorised to send mail for the primary domain. Should be the public IP of the relay every outbound message exits through. Empty string omits the SPF TXT record entirely — fine if SPF is published manually elsewhere. | `string` | `""` | no |
| <a name="input_tolerations"></a> [tolerations](#input\_tolerations) | Taints both Stalwart pods tolerate. Empty list = pods cannot land on any tainted node. Applied to both the main Deployment and the smtp-relay sidecar Deployment so neither pod is evicted by node-level taint drains. | <pre>list(object({<br/>    key                = optional(string)<br/>    operator           = optional(string)<br/>    value              = optional(string)<br/>    effect             = optional(string)<br/>    toleration_seconds = optional(string)<br/>  }))</pre> | `[]` | no |
| <a name="input_user_role_name"></a> [user\_role\_name](#input\_user\_role\_name) | Name of the Zitadel project role that grants ordinary mailbox access. Required for any user who should be able to log into Roundcube — the Zitadel project gate (`project_role_check = true`) rejects users without a project-role, so absent this grant a Zitadel org member cannot reach the mail UI at all. | `string` | `"mail-user"` | no |
| <a name="input_volume_base_path"></a> [volume\_base\_path](#input\_volume\_base\_path) | Parent path used verbatim by the hostPath PV. Stalwart's data + config + bootstrap state land at <volume\_base\_path>/<namespace>/stalwart/. Survives ./tf bootstrap-k3s on purpose — losing this dir wipes mailboxes, DKIM keys, and the bootstrap admin record. | `string` | `"/data/vol"` | no |
| <a name="input_webui_url"></a> [webui\_url](#input\_webui\_url) | URL of the upstream Stalwart WebUI bundle. Pinned to the version that ships with the server image — stale bundles drift the API contract. The init container downloads, sed-patches the OAuth client\_id, repackages, and Stalwart's Application is pointed at the local file. | `string` | `"https://github.com/stalwartlabs/webui/releases/download/v1.0.2/webui.zip"` | no |
| <a name="input_zitadel_issuer_url"></a> [zitadel\_issuer\_url](#input\_zitadel\_issuer\_url) | Zitadel public issuer URL (e.g. https://id.example.com). Used by Stalwart's OIDC directory to validate user-presented tokens via /userinfo. Empty string disables OIDC bootstrap (recovery-admin still works). | `string` | `""` | no |
| <a name="input_zitadel_org_id"></a> [zitadel\_org\_id](#input\_zitadel\_org\_id) | Zitadel organisation ID the OIDC application + role land in. Pulled from the parent module's data "zitadel\_orgs" lookup. | `string` | `""` | no |
| <a name="input_zitadel_provider_authenticated"></a> [zitadel\_provider\_authenticated](#input\_zitadel\_provider\_authenticated) | True when the root TF has been handed a non-empty TF\_VAR\_zitadel\_pat for the Zitadel provider. False trips the precondition with a clear error instead of an opaque provider 'unauthenticated' on apply. | `bool` | `false` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_account_url"></a> [account\_url](#output\_account\_url) | Stalwart self-service account URL — same random prefix as admin\_url, lands users on Stalwart's `/account` (sessions, password — mostly empty for OIDC users since password lives in Zitadel). |
| <a name="output_admin_url"></a> [admin\_url](#output\_admin\_url) | Operator-facing Stalwart admin URL — `https://mail.<domain>/<random>/admin`. The random prefix is generated once per cluster and stays stable across applies; it surfaces ONLY here and in the platform cheatsheet so admin doesn't surface on the host root (which now serves Roundcube webmail). Do not paste publicly. |
| <a name="output_dkim_dns_name"></a> [dkim\_dns\_name](#output\_dkim\_dns\_name) | Name component of the DKIM TXT record (relative to the primary domain). Concatenate with the domain to get the FQDN — e.g. `<dkim_selector>._domainkey.<primary_domain>`. |
| <a name="output_dkim_dns_value"></a> [dkim\_dns\_value](#output\_dkim\_dns\_value) | Value of the DKIM TXT record. Drop verbatim into `config/domains/<primary>.yaml`'s `dns:` block as `{ name: <dkim_selector>._domainkey, type: TXT, content: "<this>" }`. |
| <a name="output_dmarc_dns_name"></a> [dmarc\_dns\_name](#output\_dmarc\_dns\_name) | Name component of the DMARC TXT record. |
| <a name="output_dmarc_dns_value"></a> [dmarc\_dns\_value](#output\_dmarc\_dns\_value) | Recommended DMARC policy — quarantine (move-to-spam) on auth failure, aggregate reports to postmaster of the primary domain. Tighten to `p=reject` after a few weeks of clean reports. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | n/a |
| <a name="output_recovery_admin_password"></a> [recovery\_admin\_password](#output\_recovery\_admin\_password) | Plaintext password for the pinned recovery / fallback admin. Sensitive — surface with `terraform output -raw stalwart_recovery_admin_password` (root-level alias defined in outputs.tf). Bypasses the directory entirely; use whenever OIDC sign-in is broken or unavailable. |
| <a name="output_recovery_admin_secret"></a> [recovery\_admin\_secret](#output\_recovery\_admin\_secret) | Name of the Secret holding the pinned recovery / fallback admin credentials. Read username + password with `kubectl get secret <name> -n mail -o jsonpath='{.data.password}' | base64 -d`. |
| <a name="output_recovery_admin_username"></a> [recovery\_admin\_username](#output\_recovery\_admin\_username) | Username for the pinned recovery / fallback admin (always `admin`). Pairs with `recovery_admin_password` for direct WebUI login that bypasses the OIDC directory. |
| <a name="output_service_http"></a> [service\_http](#output\_service\_http) | ClusterIP Service serving Stalwart's HTTP (admin + webmail + JMAP). Cloudflare Tunnel ingress routes mail.<domain> here via a kind:external component in the domain yaml. |
| <a name="output_spf_dns_value"></a> [spf\_dns\_value](#output\_spf\_dns\_value) | Recommended SPF TXT for the primary domain — authorises only the relay's public IP and rejects everything else (`-all`). Empty when `var.spf_authorized_ip` is unset. |
| <a name="output_zitadel_admin_role"></a> [zitadel\_admin\_role](#output\_zitadel\_admin\_role) | Name of the Zitadel project role that grants Stalwart admin via the OIDC `groups` claim; null when Zitadel integration is disabled. |
| <a name="output_zitadel_application_oidc_id"></a> [zitadel\_application\_oidc\_id](#output\_zitadel\_application\_oidc\_id) | ID of the Zitadel OIDC application provisioned for Stalwart's WebUI; null when Zitadel integration is disabled. Used by the operator to grant `mail-admin` to specific users. |
| <a name="output_zitadel_project_id"></a> [zitadel\_project\_id](#output\_zitadel\_project\_id) | ID of the Zitadel project the Stalwart OIDC app + roles land in. Re-used by sibling modules (roundcube webmail) so additional OIDC clients pile under the same project rather than spawning new ones. |
| <a name="output_zitadel_user_role"></a> [zitadel\_user\_role](#output\_zitadel\_user\_role) | Name of the Zitadel project role required for ordinary mailbox access. Operator grants this (or `zitadel_admin_role`) to every Zitadel user who should reach the webmail; users without a project-role are rejected at /authorize. |
<!-- END_TF_DOCS -->
