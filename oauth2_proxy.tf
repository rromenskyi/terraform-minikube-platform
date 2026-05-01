# Cluster-wide auth gate for `kind: external` services that opt in
# via `auth: zitadel` in their component yaml. One Zitadel-backed
# oauth2-proxy in the `ingress-controller` namespace; Traefik's
# ForwardAuth middleware (also emitted by this module) bounces
# unauthenticated requests through Zitadel and lets the cookie cover
# every protected subdomain on the same parent domain.
#
# Auth + cookie domain are derived from `zitadel.external_domain`:
# `id.<parent>` → auth host `auth.<parent>`, cookie scope `.<parent>`.
# Cookies can't cross parent domains, so this proxy only protects
# subdomains of *that* parent — services on other tenants' domains
# would need their own gate, or operator-driven split routing in a
# follow-up.
#
# Gated on `services.zitadel.enabled` — when the operator runs without
# Zitadel, the module produces zero resources and any `auth: zitadel`
# on a component yaml fails the modules/project precondition with a
# clear error before Traefik gets handed a broken IngressRoute.
locals {
  # Drop the leftmost label of the Zitadel external_domain to get the
  # parent zone the proxy serves. Empty string when Zitadel is off so
  # the module receives a defined value (it's gated anyway).
  _oauth2_parent_domain = local.platform.services.zitadel.enabled ? join(
    ".",
    slice(
      split(".", local.platform.services.zitadel.external_domain),
      1,
      length(split(".", local.platform.services.zitadel.external_domain))
    )
  ) : ""
}

module "oauth2_proxy" {
  source     = "./modules/oauth2-proxy"
  depends_on = [module.addons, module.zitadel]

  enabled                        = local.platform.services.zitadel.enabled
  namespace                      = "ingress-controller"
  zitadel_provider_authenticated = var.zitadel_pat != ""

  issuer_url    = local.platform.services.zitadel.enabled ? "https://${local.platform.services.zitadel.external_domain}" : ""
  auth_hostname = local._oauth2_parent_domain == "" ? "" : "auth.${local._oauth2_parent_domain}"
  # traefik-forward-auth canonicalises the cookie domain itself —
  # pass the bare parent zone, no leading dot.
  cookie_domain = local._oauth2_parent_domain
}
