terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
  }
}

# =============================================================================
# Roundcube webmail — Zitadel-OIDC-only auth via XOAUTH2
# =============================================================================
#
# Roundcube fronts the actual mailbox UI at the root of mail.<domain>.
# Authentication is exclusively OIDC (Zitadel): the user clicks "Sign
# in with Zitadel", PKCE auth-code flow runs, Roundcube receives an
# access_token, then opens IMAP/SMTP to Stalwart with SASL XOAUTH2 +
# the same access_token. Stalwart's Oidc directory validates the
# token (issuer/aud + claim_email) and auto-provisions the
# UserAccount on first login. No app passwords, no internal
# directory, no manual provisioning.

variable "enabled" {
  type    = bool
  default = true
}

variable "namespace" {
  type = string
}

variable "hostname" {
  description = "Public hostname Roundcube is reachable at (the same one Stalwart uses; Roundcube serves root, Stalwart admin lives at /admin and /account)."
  type        = string
}

variable "volume_base_path" {
  description = "Root directory on the host node for Roundcube's preferences SQLite DB."
  type        = string
}

variable "image" {
  description = "Roundcube container image. The Apache flavour is used because the upstream image bakes a working PHP+Apache config; the alpine-fpm flavour needs an extra fpm/nginx pair."
  type        = string
  default     = "roundcube/roundcubemail:1.6.10-apache"
}

variable "imap_host" {
  description = "In-cluster Stalwart IMAP service host. TLS on port 993 (`tls://...`)."
  type        = string
  default     = "stalwart.mail.svc.cluster.local"
}

variable "imap_port" {
  type    = number
  default = 993
}

variable "smtp_host" {
  description = "In-cluster Stalwart submission service host. TLS on port 465 (`ssl://...`)."
  type        = string
  default     = "stalwart.mail.svc.cluster.local"
}

variable "smtp_port" {
  type    = number
  default = 465
}

variable "zitadel_org_id" {
  type    = string
  default = ""
}

variable "zitadel_issuer_url" {
  type    = string
  default = ""
}

variable "zitadel_provider_authenticated" {
  type    = bool
  default = false
}

variable "zitadel_project_id" {
  description = "Existing Zitadel project this Roundcube OIDC app lands under. Reusing the Stalwart-tenant project keeps role grants in one place."
  type        = string
  default     = ""
}

variable "memory_request" {
  type    = string
  default = "128Mi"
}

variable "memory_limit" {
  type    = string
  default = "512Mi"
}

variable "cpu_request" {
  type    = string
  default = "20m"
}

variable "cpu_limit" {
  type    = string
  default = "500m"
}

locals {
  enabled         = var.enabled
  oidc_enabled    = var.enabled && var.zitadel_issuer_url != "" && var.zitadel_org_id != "" && var.zitadel_project_id != ""
  instance_set    = local.enabled ? toset(["enabled"]) : toset([])
  oidc_set        = local.oidc_enabled ? toset(["enabled"]) : toset([])
  client_id       = local.oidc_enabled ? zitadel_application_oidc.roundcube["enabled"].client_id : ""
  client_secret   = local.oidc_enabled ? zitadel_application_oidc.roundcube["enabled"].client_secret : ""
  config_inc_hash = sha256(local.config_inc_php)

  # Roundcube `config.inc.php` rendered from TF. Three concerns:
  # 1. IMAP/SMTP point at Stalwart in-cluster (TLS, self-signed
  #    cert ignored — the cluster boundary is the trust boundary).
  # 2. oauth2 plugin enabled with the Zitadel issuer URL — Roundcube
  #    uses OIDC discovery to find authorize/token/userinfo.
  # 3. `oauth_scope` includes `offline_access` so Roundcube can
  #    refresh the token without bouncing the user back to Zitadel
  #    every hour.
  config_inc_php = <<-EOT
    <?php
    // Managed by terraform — modules/roundcube/main.tf. Edits here are
    // overwritten on every `./tf apply`.

    $config = [];

    $config['db_dsnw']  = 'sqlite:////var/roundcube/db/sqlite.db?mode=0640';

    $config['imap_host']     = 'ssl://${var.imap_host}:${var.imap_port}';
    $config['smtp_host']     = 'ssl://${var.smtp_host}:${var.smtp_port}';
    $config['smtp_user']     = '%u';
    $config['smtp_pass']     = '%p';

    // Cluster-internal TLS — Stalwart listener uses k8s-issued cert
    // (or self-signed); peer verification disabled because cluster
    // is the trust boundary.
    $config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
    $config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];

    $config['support_url'] = '';
    $config['product_name'] = 'Mail';
    $config['skin'] = 'elastic';
    $config['language'] = 'en_US';

    $config['session_lifetime'] = 30;
    $config['ip_check'] = false;
    $config['enable_installer'] = false;

    // Encrypts session-stored OAuth tokens at rest. Random per-deploy
    // — see `random_password.des_key` in the module.
    $config['des_key'] = getenv('ROUNDCUBE_DES_KEY');

    // OAuth2 / OIDC support is a CORE feature in Roundcube 1.5+ —
    // not a plugin. The `oauth_*` directives below activate it; no
    // entry in $config['plugins'] is needed.
    $config['plugins'] = [];

    // OIDC client config — Zitadel-managed confidential application
    // with a client secret. Roundcube 1.6 oauth2 hard-requires the
    // secret in the token-exchange request; PKCE-only public clients
    // (auth_method_type=NONE) trigger an infinite redirect loop. The
    // secret is rendered into the ConfigMap directly here for
    // simplicity — fine while it's the only consumer in the namespace
    // and the cluster boundary is the trust boundary; long-term move
    // to an env-var sourced from a Secret.
    $config['oauth_provider']        = 'generic';
    $config['oauth_provider_name']   = 'Zitadel';
    $config['oauth_client_id']       = '${local.client_id}';
    // Sourced from the `roundcube-secrets` k8s Secret via env var so
    // the live secret value never lands inside the ConfigMap. This
    // also avoids a sensitive-data drift issue where Terraform stops
    // rendering ConfigMap updates when the embedded sensitive string
    // changes — env-var injection picks up the latest Secret on
    // every pod start without ConfigMap re-render.
    $config['oauth_client_secret']   = getenv('ROUNDCUBE_OAUTH_CLIENT_SECRET');
    $config['oauth_auth_uri']        = '${var.zitadel_issuer_url}/oauth/v2/authorize';
    $config['oauth_token_uri']       = '${var.zitadel_issuer_url}/oauth/v2/token';
    $config['oauth_identity_uri']    = '${var.zitadel_issuer_url}/oidc/v1/userinfo';
    $config['oauth_logout_uri']      = '${var.zitadel_issuer_url}/oidc/v1/end_session';
    $config['oauth_scope']           = 'openid email profile offline_access';
    $config['oauth_identity_fields'] = ['email'];
    $config['oauth_login_redirect']  = true;

    // Behind Cloudflare Tunnel + Traefik. cloudflared sends HTTP to
    // Traefik on port 80; Traefik forwards to Roundcube as HTTP.
    // Roundcube needs to know the *external* scheme to build correct
    // redirect URIs back to Zitadel.
    $config['use_https']    = true;
    $config['force_https']  = false; // upstream already terminated TLS
    $config['proxy_whitelist'] = ['*'];
    $config['trusted_host_patterns'] = ['${replace(var.hostname, ".", "\\\\.")}'];

  EOT
}

# ── Zitadel project + application — Roundcube as PKCE OIDC client ─────────────
resource "zitadel_application_oidc" "roundcube" {
  for_each = local.oidc_set

  org_id     = var.zitadel_org_id
  project_id = var.zitadel_project_id

  name = "roundcube-webmail"

  redirect_uris = [
    "https://${var.hostname}/index.php/login/oauth",
  ]
  post_logout_redirect_uris = [
    "https://${var.hostname}/?_task=logout",
  ]

  response_types = ["OIDC_RESPONSE_TYPE_CODE"]
  grant_types    = ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"]
  app_type       = "OIDC_APP_TYPE_WEB"
  # BASIC, despite Roundcube wire-shape being `client_secret_post`.
  # Reason: Zitadel's TF provider only exports a populated
  # `client_secret` attribute when this is BASIC; POST and NONE come
  # back empty (provider issue or design — verified empirically by
  # comparing the four OIDC apps in this state). Most OIDC servers
  # (Zitadel included) accept BOTH client_secret_basic and
  # client_secret_post for confidential clients regardless of the
  # registered method, so a Roundcube-style form-body submission
  # against a BASIC-registered Zitadel app validates fine.
  auth_method_type = "OIDC_AUTH_METHOD_TYPE_BASIC"
  version          = "OIDC_VERSION_1_0"

  dev_mode                    = false
  access_token_type           = "OIDC_TOKEN_TYPE_JWT"
  access_token_role_assertion = true
  id_token_role_assertion     = true
  id_token_userinfo_assertion = true
  clock_skew                  = "0s"

  lifecycle {
    precondition {
      condition     = var.zitadel_provider_authenticated
      error_message = "Roundcube OIDC needs the Zitadel TF provider authenticated. See operating.md → 'Zitadel PAT bootstrap'."
    }
  }
}

# ── Per-deploy DES key for Roundcube session token encryption ─────────────────
resource "random_password" "des_key" {
  for_each = local.instance_set
  length   = 32
  special  = false
}

resource "kubernetes_secret_v1" "roundcube_secrets" {
  for_each = local.instance_set

  metadata {
    name      = "roundcube-secrets"
    namespace = var.namespace
    labels    = { app = "roundcube" }
  }

  data = {
    des_key             = random_password.des_key["enabled"].result
    oauth_client_secret = local.client_secret
  }
}

# ── ConfigMap with config.inc.php ─────────────────────────────────────────────
resource "kubernetes_config_map_v1" "roundcube_config" {
  for_each = local.instance_set

  metadata {
    name      = "roundcube-config"
    namespace = var.namespace
    labels    = { app = "roundcube" }
  }

  data = {
    "config.inc.php" = local.config_inc_php
  }
}

# ── Persistent volume for the SQLite preferences DB ───────────────────────────
resource "kubernetes_persistent_volume_v1" "roundcube" {
  for_each = local.instance_set

  metadata {
    name = "roundcube-db"
    labels = {
      "app.kubernetes.io/name"    = "roundcube"
      "app.kubernetes.io/part-of" = "platform"
    }
  }

  spec {
    capacity = { storage = "1Gi" }

    access_modes = ["ReadWriteOnce"]
    # `standard` matches what the Stalwart PV uses on this k3s cluster
    # — k3s ships `local-path` as the cluster-default StorageClass and
    # any PVC without an explicit class gets it stamped on by the
    # admission plugin. An empty class on the PV then mismatches the
    # `local-path` PVC and binding fails with `storageClassName does
    # not match`. Naming a non-default class on both sides ("standard"
    # is conventional and unused) opts out of the default-class
    # injection so the static binding works.
    storage_class_name               = "standard"
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"

    persistent_volume_source {
      host_path {
        path = "${var.volume_base_path}/${var.namespace}/roundcube"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "roundcube" {
  for_each = local.instance_set

  metadata {
    name      = "roundcube-db"
    namespace = var.namespace
    labels    = { app = "roundcube" }
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.roundcube["enabled"].metadata[0].name

    resources {
      requests = { storage = "1Gi" }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────
resource "kubernetes_service_v1" "roundcube" {
  for_each = local.instance_set

  metadata {
    name      = "roundcube"
    namespace = var.namespace
    labels    = { app = "roundcube" }
  }

  spec {
    selector = { app = "roundcube" }

    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
  }
}

# ── Deployment ────────────────────────────────────────────────────────────────
resource "kubernetes_deployment_v1" "roundcube" {
  for_each = local.instance_set

  metadata {
    name      = "roundcube"
    namespace = var.namespace
    labels    = { app = "roundcube" }

    annotations = {
      "platform.local/config-hash" = local.config_inc_hash
    }
  }

  spec {
    replicas = 1

    strategy { type = "Recreate" }

    selector {
      match_labels = { app = "roundcube" }
    }

    template {
      metadata {
        labels = { app = "roundcube" }
        annotations = {
          "platform.local/config-hash" = local.config_inc_hash

          # Rolls the pod when the OIDC Secret content changes — same
          # rationale as `modules/component`'s `pod_annotations.checksum/oidc`:
          # K8s does NOT auto-rollout pods on Secret-data change for
          # envFrom-mounted vars (env is read at process start). The
          # client_secret is consumed via env (`ROUNDCUBE_OAUTH_CLIENT_SECRET`),
          # not interpolated into config_inc_php, so a Zitadel app rotation
          # that shifts client_secret independently of client_id would slip
          # past the config-hash above without this. `nonsensitive()` drops
          # the sensitivity bit on the hash output (the hash itself reveals
          # nothing).
          "platform.local/oidc-hash" = local.oidc_enabled ? nonsensitive(sha1(jsonencode({
            issuer        = var.zitadel_issuer_url
            client_id     = local.client_id
            client_secret = local.client_secret
            des_key       = random_password.des_key["enabled"].result
          }))) : ""
        }
      }

      spec {
        # hostPath volumes mount with the host directory's existing
        # ownership (root:root in our case). Roundcube's apache process
        # runs as www-data (uid 33) and the SQLite file lives in
        # /var/roundcube/db; without an explicit chown the main container
        # cannot create sqlite.db and every page fails with
        # `SQLSTATE[HY000] [14] unable to open database file`. The init
        # container fixes ownership once at pod start.
        init_container {
          name    = "fix-db-perms"
          image   = "busybox:1.36"
          command = ["sh", "-c", "chown -R 33:33 /var/roundcube/db"]

          volume_mount {
            name       = "db"
            mount_path = "/var/roundcube/db"
          }

          security_context {
            run_as_user = 0
          }

          resources {
            requests = { cpu = "10m", memory = "8Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }

        container {
          name  = "roundcube"
          image = var.image

          # Upstream image reads /var/roundcube/config/*.inc.php as
          # additional config (merged after defaults). Mounting our
          # config.inc.php there lets us drive everything declaratively
          # without any image rebuild or env-var translation layer.
          volume_mount {
            name       = "config"
            mount_path = "/var/roundcube/config/config.inc.php"
            sub_path   = "config.inc.php"
            read_only  = true
          }

          # SQLite DB lives in a persistent volume so user prefs,
          # contacts, and the cached IMAP folder list survive pod
          # restarts.
          volume_mount {
            name       = "db"
            mount_path = "/var/roundcube/db"
          }

          env {
            name = "ROUNDCUBE_DES_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.roundcube_secrets["enabled"].metadata[0].name
                key  = "des_key"
              }
            }
          }

          env {
            name = "ROUNDCUBE_OAUTH_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.roundcube_secrets["enabled"].metadata[0].name
                key  = "oauth_client_secret"
              }
            }
          }

          # Defaults so the upstream image's bootstrap script doesn't
          # try to rewrite our config (it skips its own template when
          # these are unset and a user-supplied config.inc.php exists).
          env {
            name  = "ROUNDCUBEMAIL_DB_TYPE"
            value = "sqlite"
          }

          port {
            container_port = 80
            protocol       = "TCP"
          }

          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              cpu    = var.cpu_limit
              memory = var.memory_limit
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.roundcube_config["enabled"].metadata[0].name
            items {
              key  = "config.inc.php"
              path = "config.inc.php"
            }
          }
        }

        volume {
          name = "db"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.roundcube["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "service_name" {
  value = var.enabled ? kubernetes_service_v1.roundcube["enabled"].metadata[0].name : null
}

output "namespace" {
  value = var.namespace
}

output "zitadel_application_oidc_id" {
  value = local.oidc_enabled ? zitadel_application_oidc.roundcube["enabled"].id : null
}
