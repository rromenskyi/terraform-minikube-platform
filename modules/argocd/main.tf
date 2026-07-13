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
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
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
  values = yamlencode({
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

    # The repo-server's health endpoint stalls past the chart-default 1s probe
    # timeout while it is busy generating manifests on this box (observed 5s+
    # responses → liveness kill → CrashLoopBackOff every few minutes for days;
    # controllers then see "name resolver error: produced zero addresses"
    # between restarts). Generous timeouts keep a busy-but-healthy repo-server
    # alive without masking a truly wedged one.
    repoServer = {
      livenessProbe = {
        timeoutSeconds   = 10
        failureThreshold = 5
      }
      readinessProbe = {
        timeoutSeconds   = 10
        failureThreshold = 5
      }
    }

    # Deploy notifications (operator ruling 2026-07-06: Slack, not Telegram).
    # This block ALSO adopts config that previously drifted outside TF — the
    # app-deployed template/trigger were hand-applied to the live CM; from
    # here on the chart renders them. The Slack INCOMING WEBHOOK URL is a
    # secret and is NOT in TF: the chart-managed secret is disabled and a
    # VaultStaticSecret (below) syncs
    # `secret/platform/slack/argocd-notifications` (key `slack-webhook`)
    # into `argocd-notifications-secret`.
    notifications = {
      argocdUrl = "https://${var.hostname}"
      notifiers = {
        # Slack INCOMING WEBHOOK (operator ruling 2026-07-06) — the channel is
        # baked into the URL, which lives in Vault (key slack-webhook), never
        # in this repo.
        "service.webhook.slack-deploys" = <<-EOT
          url: $slack-webhook
          headers:
            - name: Content-Type
              value: application/json
        EOT
      }
      templates = {
        "template.app-deployed" = <<-EOT
          webhook:
            slack-deploys:
              method: POST
              body: |
                {{- $line := printf "revision: %s" .app.status.sync.revision -}}
                {{- if has .app.metadata.name (list "lineoneagent-frontend-dev" "lineoneagent-backend-dev" "lineoneagent-sipmesh-dev") -}}
                  {{- $bump := call .repo.GetCommitMetadata .app.status.sync.revision -}}
                  {{- $sha := regexFind "built-from=[0-9a-f]{7,40}" $bump.Message | trimPrefix "built-from=" -}}
                  {{- if $sha -}}
                    {{- $real := call .repo.GetCommitMetadata $sha -}}
                    {{- $line = printf "`%s` — `%s`\n`%s`" (trunc 7 $sha) (first (splitList "\n" $real.Message) | replace "`" "'") (trim (regexFind "^[^<]+" $real.Author) | replace "`" "'") -}}
                  {{- end -}}
                {{- end -}}
                {"text": {{ toJson (printf "Deployed: %s\n%s\n%s/applications/%s" .app.metadata.name $line .context.argocdUrl .app.metadata.name) }}}
        EOT
      }
      triggers = {
        "trigger.on-deployed" = <<-EOT
          - description: Application is synced and healthy. Triggered once per commit.
            oncePer: app.status.sync.revision
            when: app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy' and (app.metadata.name not in ['lineoneagent-frontend-dev','lineoneagent-backend-dev','lineoneagent-sipmesh-dev'] or repo.GetCommitMetadata(app.status.sync.revision).Message matches 'built-from=')
            send:
              - app-deployed
        EOT
      }
      secret = {
        create = false # owned by VSO (Vault → argocd-notifications-secret)
      }
    }
  })
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


# ── Slack notifications secret (Vault → VSO) ──────────────────────────────
# The chart's own notifications secret is disabled (`secret.create=false`);
# VSO owns `argocd-notifications-secret` instead. The Slack incoming-webhook
# URL for the deploys channel lives at
# `secret/data/platform/slack/argocd-notifications` under the key
# `slack-webhook`; VSO syncs it here and rotation is a Vault edit, no TF.

# The consuming-namespace SA `vault-secrets-operator-controller-manager`
# already exists in the argocd namespace (root argocd_repos.tf emits it for
# Vault-mode repo creds) — this VSS rides the same auth.
resource "kubectl_manifest" "notifications_secret_vault" {
  for_each = var.enabled ? toset(["enabled"]) : toset([])

  yaml_body = yamlencode({
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "argocd-notifications-slack"
      namespace = var.namespace
    }
    spec = {
      vaultAuthRef = ""
      mount        = "secret"
      type         = "kv-v2"
      path         = "platform/slack/argocd-notifications"
      destination = {
        name   = "argocd-notifications-secret"
        create = true
      }
      refreshAfter = "30s"
    }
  })
}
