# ── Zitadel project + application + role ──────────────────────────────────────
#
# Single project per Stalwart tenant. PKCE / SPA OIDC application —
# the WebUI is a public client with no secret, redirect URIs cover
# both /admin and /account mount points (the WebUI computes its own
# redirect_uri at runtime from window.location.origin + base path).
# `mail-admin` role is what an operator assigns to a Zitadel user to
# grant Stalwart admin; the role name flows through the id_token's
# `groups` claim to the matching Stalwart group.

resource "zitadel_project" "stalwart" {
  for_each = local.oidc_set

  org_id = var.zitadel_org_id
  name   = "stalwart"

  # `project_role_assertion = true` puts the user's project-roles
  # into the id_token / userinfo `groups` claim — Stalwart's
  # claimGroups consumes them to assign Group membership for the
  # auto-provisioned UserAccount.
  project_role_assertion = true

  # `project_role_check = true` is the auth gate — Zitadel rejects
  # /authorize if the user has NO role on this project. Operator
  # grants `mail-user` (or `mail-admin`) to anyone who should have
  # a mailbox; everyone else gets a Zitadel-side "Forbidden" before
  # Roundcube sees the request. Without this flag, every Zitadel
  # org member could log in and Stalwart would auto-provision them
  # a mailbox.
  project_role_check = true

  has_project_check        = false
  private_labeling_setting = "PRIVATE_LABELING_SETTING_UNSPECIFIED"

  lifecycle {
    precondition {
      condition     = var.zitadel_provider_authenticated
      error_message = "Stalwart OIDC needs a Zitadel PAT. Bootstrap once: `kubectl get secret zitadel-tf-pat -n platform -o jsonpath='{.data.access_token}' | base64 -d`, paste it into `.env` as `TF_VAR_zitadel_pat=...`. See operating.md → 'Zitadel PAT bootstrap'."
    }
  }
}

resource "zitadel_application_oidc" "stalwart" {
  for_each = local.oidc_set

  org_id     = var.zitadel_org_id
  project_id = zitadel_project.stalwart["enabled"].id

  name = "stalwart-webui"

  # Stalwart WebUI builds its own redirect URI as
  # ${origin}${basePath}/oauth/callback at runtime. basePath is one
  # of /<random>/admin or /<random>/account (URL-obscured so the UI
  # doesn't surface on the public root, where Roundcube lives) — both
  # are registered with the Zitadel app.
  redirect_uris = [
    "${local.admin_origin}/admin/oauth/callback",
    "${local.admin_origin}/account/oauth/callback",
  ]
  post_logout_redirect_uris = [
    "${local.admin_origin}/admin/login",
    "${local.admin_origin}/account/login",
  ]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_USER_AGENT"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_NONE"
  version          = "OIDC_VERSION_1_0"

  dev_mode                    = false
  access_token_type           = "OIDC_TOKEN_TYPE_JWT"
  access_token_role_assertion = true
  id_token_role_assertion     = true
  id_token_userinfo_assertion = true
  clock_skew                  = "0s"
}

# OIDC app for native desktop/mobile mail clients (Apple Mail, Thunderbird) that
# reach Stalwart through a local email-oauth2-proxy: browser auth-code + PKCE
# against Zitadel, then XOAUTH2 to Stalwart's IMAP/SMTP. Created ONLY when the
# native-client listeners are published (`client_listen_ip`). In the SAME
# project as the WebUI app, so its JWT access token carries the project-id
# audience Stalwart's `requireAudience` checks. Native app + loopback redirect
# (RFC 8252 — any localhost port matches) + PKCE (no client secret to store).
resource "zitadel_application_oidc" "stalwart_native_client" {
  for_each = var.client_listen_ip != "" ? local.oidc_set : toset([])

  org_id     = var.zitadel_org_id
  project_id = zitadel_project.stalwart["enabled"].id

  name = "stalwart-native-client"

  redirect_uris = ["http://localhost"]

  response_types   = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types      = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type         = "OIDC_APP_TYPE_NATIVE"
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_NONE"
  version          = "OIDC_VERSION_1_0"

  dev_mode          = true
  access_token_type = "OIDC_TOKEN_TYPE_JWT"
}

resource "zitadel_project_role" "admin" {
  for_each = local.oidc_set

  org_id       = var.zitadel_org_id
  project_id   = zitadel_project.stalwart["enabled"].id
  role_key     = var.admin_role_name
  display_name = "Mail admin"
  group        = var.admin_role_name
}

# `mail-user` — the everyday mailbox role. The Zitadel project gate
# (`project_role_check = true`) requires every authorising user to hold
# at least one project-role; a user with neither `mail-user` nor
# `mail-admin` is rejected at /authorize before Roundcube/Stalwart see
# the request. Operator grants `mail-user` to each Zitadel user who
# should have a mailbox, full stop.
resource "zitadel_project_role" "user" {
  for_each = local.oidc_set

  org_id       = var.zitadel_org_id
  project_id   = zitadel_project.stalwart["enabled"].id
  role_key     = var.user_role_name
  display_name = "Mail user"
  group        = var.user_role_name
}

# ── Recovery / fallback admin secret ──────────────────────────────────────────
#
# STALWART_RECOVERY_ADMIN is honoured both in recovery mode and in
# normal mode, bypassing the directory. The upstream docs frame it
# as a backdoor that should be removed after bootstrap; for our
# single-operator setup behind a Zitadel-gated network it doubles
# as a permanent fallback admin (cookie expired, OIDC down, etc.).
# Read with: `kubectl get secret stalwart-recovery-admin -n mail \
#   -o jsonpath='{.data.password}' | base64 -d`.
