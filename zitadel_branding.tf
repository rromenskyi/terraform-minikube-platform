# Login page branding: Zitadel's instance-wide default label policy
# (logo, icon, colours for light and dark theme), shown by the hosted
# login UI. Driven by `services.zitadel.branding` in config/platform.yaml;
# asset paths are relative to the repo root (keep them under the
# gitignored config/branding/). No `branding` block = Zitadel defaults.

locals {
  _zitadel_branding = try(local.platform.services.zitadel.branding, null)
  _zitadel_assets = {
    for k in ["logo", "logo_dark", "icon", "icon_dark"] :
    k => "${path.root}/${local._zitadel_branding[k]}"
    if try(local._zitadel_branding[k], "") != ""
  }
}

resource "zitadel_default_label_policy" "this" {
  for_each = local.platform.services.zitadel.enabled && local._zitadel_branding != null ? toset(["enabled"]) : toset([])

  primary_color         = try(local._zitadel_branding.primary_color, "")
  background_color      = try(local._zitadel_branding.background_color, "")
  font_color            = try(local._zitadel_branding.font_color, "")
  warn_color            = try(local._zitadel_branding.warn_color, "")
  primary_color_dark    = try(local._zitadel_branding.primary_color_dark, "")
  background_color_dark = try(local._zitadel_branding.background_color_dark, "")
  font_color_dark       = try(local._zitadel_branding.font_color_dark, "")
  warn_color_dark       = try(local._zitadel_branding.warn_color_dark, "")
  theme_mode            = try(local._zitadel_branding.theme_mode, "THEME_MODE_AUTO")

  hide_login_name_suffix = try(local._zitadel_branding.hide_login_name_suffix, false)
  disable_watermark      = try(local._zitadel_branding.disable_watermark, false)


  # Apply the policy right away instead of leaving it as a preview.
  set_active = true
}

# Logo and icon upload. The provider uploads assets only with a JWT
# profile key, and this platform authenticates to Zitadel with a PAT, so
# a Job in the cluster uploads them through the assets API with the same
# PAT (the shell below runs in that pod) and then activates the policy,
# which assets otherwise leave in preview. The Job name carries a hash
# of the files: replacing an image re-runs it.
locals {
  _zitadel_asset_routes = {
    logo      = "logo"
    logo_dark = "logo/dark"
    icon      = "icon"
    icon_dark = "icon/dark"
  }
  _zitadel_assets_hash = substr(md5(join(",", [for k in sort(keys(local._zitadel_assets)) : "${k}=${filemd5(local._zitadel_assets[k])}"])), 0, 10)
}

resource "kubernetes_config_map_v1" "zitadel_branding_assets" {
  for_each = length(zitadel_default_label_policy.this) > 0 && length(local._zitadel_assets) > 0 ? toset(["enabled"]) : toset([])

  metadata {
    name      = "zitadel-branding-assets"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  binary_data = { for k, f in local._zitadel_assets : "${k}.png" => filebase64(f) }
}

resource "kubernetes_job_v1" "zitadel_branding_assets" {
  for_each = kubernetes_config_map_v1.zitadel_branding_assets

  depends_on = [zitadel_default_label_policy.this]

  metadata {
    name      = "zitadel-branding-${local._zitadel_assets_hash}"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  spec {
    backoff_limit              = 3
    ttl_seconds_after_finished = 86400

    template {
      metadata {}
      spec {
        restart_policy = "Never"

        container {
          name    = "upload"
          image   = "curlimages/curl:8.16.0"
          command = ["sh", "-c"]
          args = [<<-EOT
            set -eu
            api="http://zitadel.${kubernetes_namespace_v1.platform.metadata[0].name}.svc.cluster.local:8080"
            # Zitadel picks the instance by host, so present the public one.
            hdr="-H Host:${local.platform.services.zitadel.external_domain} -H X-Forwarded-Proto:https"
            for pair in ${join(" ", [for k in sort(keys(local._zitadel_assets)) : "${k}:${local._zitadel_asset_routes[k]}"])}; do
              key=$${pair%%:*}; route=$${pair#*:}
              echo "upload $key"
              curl -fsS $hdr -H "Authorization: Bearer $PAT" -F "file=@/assets/$key.png;type=image/png" "$api/assets/v1/instance/policy/label/$route"
            done
            echo "activate label policy"
            curl -fsS $hdr -H "Authorization: Bearer $PAT" -H "Content-Type: application/json" -d '{}' "$api/admin/v1/policies/label/_activate"
            echo done
          EOT
          ]

          env {
            name = "PAT"
            value_from {
              secret_key_ref {
                name = "zitadel-tf-pat"
                key  = "access_token"
              }
            }
          }

          volume_mount {
            name       = "assets"
            mount_path = "/assets"
            read_only  = true
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "64Mi" }
          }
        }

        volume {
          name = "assets"
          config_map {
            name = kubernetes_config_map_v1.zitadel_branding_assets["enabled"].metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
  }
}
