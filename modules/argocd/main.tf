# Argo CD — application-layer GitOps controller.
#
# Deploys the upstream `argo/argo-cd` Helm chart with the chart-side
# Ingress disabled. The platform owns ingress concerns elsewhere
# (Cloudflare Tunnel + Traefik IngressRoute) so the route lands as a
# `kind: external` component pointing at the `argocd-server` Service
# this chart creates.
#
# OIDC is wired through Dex's built-in OIDC connector. Caller is
# responsible for creating the Zitadel application (see
# `argocd.tf` at the root) and passing in `client_id` /
# `client_secret`. Empty inputs collapse the OIDC config and the
# install falls back to the chart-generated local `admin` account.

terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}


# ── Locals ────────────────────────────────────────────────────────────────

locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  oidc_complete = (
    var.oidc_issuer != "" &&
    var.oidc_client_id != "" &&
    var.oidc_client_secret != ""
  )

  # Chart values. `commonLabels` propagates to every chart-rendered
  # resource. Server-config is built conditionally so empty OIDC
  # inputs don't render a half-shaped `oidc.config` block.
  base_values = {
    global = {
      nodeSelector = var.node_selector
      tolerations = [
        for t in var.tolerations : {
          key               = t.key
          operator          = t.operator
          value             = t.value
          effect            = t.effect
          tolerationSeconds = try(tonumber(t.toleration_seconds), null)
        }
      ]
    }

    configs = {
      # `server.insecure = true` runs argocd-server with `--insecure`
      # — TLS termination happens upstream (cloudflared → Traefik),
      # the in-cluster hop is plain HTTP. Without this, argocd-server
      # marks its session cookies `Secure` while seeing each request
      # as HTTP and the browser then refuses to send the cookie
      # back, producing an infinite OIDC redirect loop on first
      # sign-in. The chart wires this key into `argocd-cmd-params-cm`
      # which the server reads as `--insecure` at start.
      params = {
        "server.insecure" = "true"
      }

      cm = merge(
        {
          url = "https://${var.hostname}"
        },
        local.oidc_complete ? {
          "oidc.config" = yamlencode({
            name         = "OIDC"
            issuer       = var.oidc_issuer
            clientID     = var.oidc_client_id
            clientSecret = var.oidc_client_secret
            requestedScopes = [
              "openid",
              "profile",
              "email",
              "groups",
            ]
            requestedIDTokenClaims = {
              groups = { essential = true }
            }
          })
        } : {}
      )

      rbac = length(var.oidc_admin_groups) == 0 ? {} : {
        "policy.csv" = join("\n", [
          for grp in var.oidc_admin_groups :
          "g, ${grp}, role:admin"
        ])
        scopes = "[groups]"
      }
    }

    # Chart-side Ingress stays off by design. The platform's
    # IngressRoute (rendered by modules/project from a `kind:
    # external` component yaml) routes Cloudflare Tunnel traffic to
    # the `argocd-server` Service the chart creates — owning ingress
    # in two places at once would conflict at the IngressClass level.
    server = {
      ingress = {
        enabled = false
      }
    }
  }

  # Argo CD notifications, folded into the chart values so the chart
  # renders `argocd-notifications-cm` + `argocd-notifications-secret`
  # itself. Without this a `helm upgrade` overwrites the live (kubectl-
  # patched) CM and wipes the telegram token, since both objects are
  # already Helm-managed. `argocdUrl` is forced from `var.hostname` to
  # stay single-sourced with `configs.cm.url`. An empty
  # `notifications_config` collapses the block, so callers that don't
  # opt in render byte-identical values and see no change.
  notifications_values = length(var.notifications_config) == 0 ? {} : {
    notifications = merge(var.notifications_config, {
      argocdUrl = "https://${var.hostname}"
      secret = {
        create = true
        items  = var.telegram_token != "" ? { "telegram-token" = var.telegram_token } : {}
      }
    })
  }

  values = yamlencode(merge(local.base_values, local.notifications_values))
}

# ── Resources ─────────────────────────────────────────────────────────────

resource "helm_release" "argocd" {
  for_each = local.instances

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.version_pin
  namespace  = var.namespace
  # Namespace owned by the caller — the OIDC Secret rendered by
  # `module.argocd_oidc` lands in the same namespace and needs it
  # to exist before the chart upgrade hook fires.
  create_namespace = false

  # Chart bring-up is heavier than monitoring (operator + repo-server
  # + application-controller + dex + redis). 15 min covers cold image
  # pulls on a slow link without masking real failures.
  timeout = 900

  values = [local.values]
}

