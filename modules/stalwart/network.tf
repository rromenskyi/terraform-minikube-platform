# ── Services ──────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "stalwart_http" {
  for_each = local.instances

  metadata {
    name      = "stalwart"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart" })
  }

  spec {
    selector = { app = "stalwart" }

    port {
      name        = "http"
      port        = 8080
      target_port = local.http_target
      protocol    = "TCP"
    }

    # IMAPS for in-cluster webmail (Roundcube) and IMAP clients
    # tunnelling through the Cloudflare host. Stalwart's listener
    # autostarts on :993 inside the pod (see startup logs); Service
    # just needs to expose it.
    port {
      name        = "imaps"
      port        = 993
      target_port = 993
      protocol    = "TCP"
    }

    # SMTP submission with implicit TLS — Roundcube sends outbound
    # via this port; Stalwart receives, applies its outbound queue
    # rules (smart-host route when configured).
    port {
      name        = "submissions"
      port        = 465
      target_port = 465
      protocol    = "TCP"
    }

    # Sieve management (filter scripts) — `managesieve` plugin in
    # Roundcube uses this if enabled. Cheap to expose now, no
    # consumer yet.
    port {
      name        = "sieve"
      port        = 4190
      target_port = 4190
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_service_v1" "stalwart_smtp" {
  for_each = local.instances

  metadata {
    name      = "stalwart-smtp"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart" })
  }

  spec {
    selector = { app = "stalwart" }

    port {
      name        = "smtp"
      port        = 25
      target_port = local.smtp_target
      protocol    = "TCP"
    }
  }
}

# ── Stalwart admin / account IngressRoutes (URL-obscured) ────────────────────
# `mail.<domain>/<random-prefix>/admin` and `/<random-prefix>/account`
# claim the operator-only Stalwart UI back from the default mail.yaml
# IngressRoute (which now serves Roundcube webmail at the host root).
# Priority 100 puts these ahead of the project-generated
# IngressRoute. The random prefix is cosmetic obscurity — there is
# still proper OIDC auth at the application layer; the prefix just
# keeps drive-by scans off the login screen.
resource "kubectl_manifest" "stalwart_admin_ingressroute" {
  # Prefix-on-mail-host routing — superseded by the LAN-only socat admin proxy
  # when `admin_hostname` is set (Stalwart serves webadmin only at bare `/admin`,
  # so a prefixed path 404s and can't be stripped — it ignores X-Forwarded-Prefix).
  for_each = var.admin_hostname == "" ? local.instances : toset([])

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "stalwart-admin"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match    = "Host(`${var.hostname}`) && PathPrefix(`${local.admin_path_prefix}/admin`)"
        kind     = "Rule"
        priority = 100
        services = [{
          name = kubernetes_service_v1.stalwart_http["enabled"].metadata[0].name
          port = 8080
        }]
      }]
    }
  })
}

resource "kubectl_manifest" "stalwart_account_ingressroute" {
  for_each = var.admin_hostname == "" ? local.instances : toset([])

  yaml_body = yamlencode({
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "stalwart-account"
      namespace = var.namespace
      labels    = local.tags
    }
    spec = {
      entryPoints = ["web"]
      routes = [{
        match    = "Host(`${var.hostname}`) && PathPrefix(`${local.admin_path_prefix}/account`)"
        kind     = "Rule"
        priority = 100
        services = [{
          name = kubernetes_service_v1.stalwart_http["enabled"].metadata[0].name
          port = 8080
        }]
      }]
    }
  })
}
