# Zitadel Actions — server-side claim mappers run in Zitadel's
# embedded V8 sandbox before tokens / userinfo are issued. Used here
# to bridge Zitadel's structured project-role claim
# (`urn:zitadel:iam:org:project:roles`) to the flat OIDC-standard
# `groups` claim that RFC-compliant OIDC clients (Argo CD, Grafana,
# Vault, oauth2-proxy when matching by group, …) consume by default.
#
# Without this Action: tokens carry roles only under the Zitadel-
# specific claim path. Argo CD's `argocd-rbac-cm.scopes: '[groups]'`
# reads the missing `groups` claim, sees nothing, falls through to
# `policy.default: ""` — every Zitadel-authenticated user lands as
# unauthorised. Manual `g, <user>, role:admin` policy entries work
# but require per-user maintenance.
#
# After this Action: every JWT issued by Zitadel carries
# `groups: ["argocd_admin", "user", "platform_admin", ...]` — the
# union of role keys across every project the authenticating user
# is granted in. Argo CD's existing
# `g, argocd_admin, role:admin` mapping then matches.
#
# The Action is org-scoped (lives on the platform org), runs on the
# `complement_token` / `pre_userinfo_creation` flow trigger
# (covers both UserInfo endpoint responses and ID token claims),
# 10-second timeout, `allowed_to_fail = false` so a regression in
# the script breaks logins loudly instead of silently issuing
# tokens without the bridged claim.

resource "zitadel_action" "groups_claim" {
  count = local.platform.services.zitadel.enabled ? 1 : 0

  org_id  = data.zitadel_orgs.platform_org[0].ids[0]
  name    = "groups_claim_from_project_roles"
  timeout = "10s"
  # `allowed_to_fail = true` — defensive default for an Action that
  # runs on EVERY Zitadel token / userinfo issue across every app
  # in the org (Stalwart, Roundcube, platform-dash, sipmesh-frontend,
  # Argo CD, oauth2-proxy). A regression in the JS would otherwise
  # take down ALL logins simultaneously. With true, a script error
  # logs to Zitadel's audit trail and the token issues without the
  # `groups` claim — Argo CD reverts to the "no groups, no role"
  # state we have today (status quo), other apps stay unaffected.
  allowed_to_fail = true

  # Iterates the user's project-role grants and emits the union of
  # role keys as a flat string array under the `groups` claim. The
  # canonical accessor for action runtime is `ctx.v1.user.grants`
  # which returns a UserGrantList — `.grants` is the array of
  # individual UserGrant objects, each carrying a `.roles` string
  # array. Use `api.v1.claims.setClaim()` (the
  # `api.v1.userinfo.appendClaim` shape is deprecated in newer
  # Zitadel runtimes). Note: claim keys prefixed `urn:zitadel:iam`
  # are silently ignored by setClaim — `groups` is unprefixed and
  # passes.
  # Function name MUST match action's `name` field exactly — Zitadel
  # V8 sandbox loads the script and invokes the function whose
  # identifier equals `action.name`. Mismatch yields silent
  # `action run failed: function not found` in zitadel-server logs;
  # the rest of the auth flow proceeds without the claim
  # (allowed_to_fail = true).
  script = <<-JS
    function groups_claim_from_project_roles(ctx, api) {
      var groups = [];
      var seen = {};
      var grants = (ctx.v1.user && ctx.v1.user.grants && ctx.v1.user.grants.grants) || [];
      for (var i = 0; i < grants.length; i++) {
        var roles = grants[i].roles || [];
        for (var j = 0; j < roles.length; j++) {
          if (!seen[roles[j]]) {
            seen[roles[j]] = true;
            groups.push(roles[j]);
          }
        }
      }
      api.v1.claims.setClaim('groups', groups);
    }
  JS
}

# Wire the Action onto the `customise_token` flow's
# `pre_userinfo_creation` trigger. Zitadel runs this trigger BEFORE
# composing the UserInfo endpoint response and BEFORE signing the
# ID token, so claims appended here land in both surfaces — which is
# what OIDC clients consume. (Provider 2.12.6 enum is
# `FLOW_TYPE_CUSTOMISE_TOKEN` — the underlying Zitadel flow named
# "complement_token" in older docs was renamed; the trigger types
# stayed `PRE_*_CREATION`.)
resource "zitadel_trigger_actions" "groups_claim_userinfo" {
  count = local.platform.services.zitadel.enabled ? 1 : 0

  org_id       = data.zitadel_orgs.platform_org[0].ids[0]
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = "TRIGGER_TYPE_PRE_USERINFO_CREATION"

  action_ids = [zitadel_action.groups_claim[0].id]
}

# Same script also runs on access-token issuance so service-side
# bearer-token verification (Argo CD CLI, future API automations)
# sees the same `groups` claim shape as interactive UI sessions.
# Trigger is independent — tokens go through a separate Zitadel
# pipeline.
resource "zitadel_trigger_actions" "groups_claim_access_token" {
  count = local.platform.services.zitadel.enabled ? 1 : 0

  org_id       = data.zitadel_orgs.platform_org[0].ids[0]
  flow_type    = "FLOW_TYPE_CUSTOMISE_TOKEN"
  trigger_type = "TRIGGER_TYPE_PRE_ACCESS_TOKEN_CREATION"

  action_ids = [zitadel_action.groups_claim[0].id]
}
