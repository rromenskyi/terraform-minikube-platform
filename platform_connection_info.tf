# Aggregated platform connection info for downstream consumers.
#
# Sibling Terraform stacks (separate clouds / backends / tenants)
# and other tooling that needs to plug into this platform read
# these coordinates to discover IdP, secrets-store, ingress base,
# and CI runner labels — without grepping `config/platform.yaml`
# or copy-pasting hostnames.
#
# Tiering:
#
#   - Tier 1 (this output): public, externally-reachable coordinates.
#     Hostnames a consumer outside the cluster can resolve and connect
#     to (OIDC issuer URL, Vault address, mail hostname, ARC scale set
#     `runs-on:` labels). No secrets, never. Schema is additive — new
#     fields may appear; existing fields stay.
#
#   - Tier 2 (NOT here): in-cluster coordinates (Service DNS like
#     `mysql.platform.svc.cluster.local`). Useless from outside the
#     cluster. Will be surfaced via a `ConfigMap platform-info` in
#     the `platform` ns when an in-cluster consumer actually wants
#     them.
#
#   - Tier 3 (NOT here): secrets. Vault at convention paths;
#     consumer reads via VSO.

output "platform_connection_info" {
  description = "Public, non-secret coordinates downstream consumers (other Terraform stacks, workflow files in sibling repos, operator tooling) use to plug into this platform. All fields are externally-resolvable hostnames or stable identifiers — no secrets, no in-cluster-only Service DNS. Fields collapse to `\"\"` / `{}` when the corresponding service is disabled. Schema is additive — consumers should tolerate unknown fields. For secrets, read Vault directly; for in-cluster Service coordinates, mount the `platform-info` ConfigMap (separate change)."
  value = {
    # Public URL of the Zitadel OIDC issuer. Consumers append
    # `/.well-known/openid-configuration` for discovery. Empty when
    # zitadel disabled.
    oidc_issuer_url = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""

    # Public URL of the Vault community platform. Consumers use this
    # as `VAULT_ADDR`. Auth method (root token vs Zitadel JWT vs
    # k8s-SA) is consumer's concern. Empty when vault disabled.
    vault_addr = local.platform.services.vault.enabled ? "https://${local.platform.services.vault.hostname}" : ""

    # Primary mail domain — convenient for consumers that want to
    # derive `admin@${primary_domain}` or similar without re-reading
    # the operator-side domain yaml. Empty when no mail domain
    # configured.
    mail_primary_domain = try(local.mail.primary_domain, "")

    # Public hostname Roundcube webmail serves at — full URL the
    # operator / agent would paste into a browser. Empty when mail
    # not configured.
    mail_webmail_hostname = try(local.mail.hostname, "")

    # Map of installed ARC scale sets — see
    # `output.github_runners_scale_set_info` for the single-output
    # form. Mirrored here so a consumer can read one aggregated
    # output instead of two.
    github_runners = module.github_runners.scale_sets
  }
}
