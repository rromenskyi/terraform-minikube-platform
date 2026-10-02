# ── Stalwart Deployment ───────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "stalwart" {
  for_each = local.instances

  metadata {
    name      = "stalwart"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart" })

    annotations = {
      # Force Pod restart when seed changes — without this, a
      # config.json or plan.ndjson edit only takes effect on the
      # next unrelated rollout.
      "platform.local/seed-hash" = sha256(nonsensitive("${local.config_json}|${local.plan_ndjson}|${local.webui_client_id}"))
    }
  }

  spec {
    # Recreate over RollingUpdate — SQLite is single-writer; surge
    # would have two pods racing on the same DB file.
    strategy {
      type = "Recreate"
    }

    replicas = 1

    selector {
      match_labels = { app = "stalwart" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "stalwart" })

        annotations = {
          "platform.local/seed-hash" = sha256(nonsensitive("${local.config_json}|${local.plan_ndjson}|${local.webui_client_id}"))
        }
      }

      spec {
        # Pin to the data-bearing node — the hostPath PV under
        # `var.volume_base_path` only lives on the original
        # bootstrap node; an unpinned pod can land elsewhere and
        # come up against an empty data dir.
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        # Explicit "default" — the kubernetes TF provider doesn't
        # reliably clear a previously-set string field by omission,
        # so removing this line silently leaves the live Deployment
        # pinned to whatever SA was last assigned.
        service_account_name = "default"

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key                = toleration.value.key
            operator           = toleration.value.operator
            value              = toleration.value.value
            effect             = toleration.value.effect
            toleration_seconds = toleration.value.toleration_seconds
          }
        }

        # ── Init containers ─────────────────────────────────────
        #
        # 1) bootstrap: writes config.json into the data PV (idempotent
        #    overwrite — small file, only datastore stanza), patches the
        #    upstream WebUI bundle with our Zitadel client_id and places
        #    the result on /shared, downloads stalwart-cli onto /shared.
        # 2) wait-zitadel (OIDC only): block the main container until the
        #    configured issuer is reachable, so a node reboot can't start
        #    Stalwart before Zitadel is back and leave it rejecting every
        #    OIDC token + serving no TLS until manually restarted. Bounded
        #    wait then starts anyway, so a down Zitadel never blocks SMTP.
        init_container {
          name  = "bootstrap"
          image = "alpine:3.22"

          security_context {
            run_as_user = 0
          }

          # Explicit resources — bootstrap downloads stalwart-cli
          # (~10MB tarball) and the WebUI bundle (~500KB) and runs
          # unzip + sed + zip on the latter. The namespace's
          # LimitRange default of 32Mi OOM-kills the apk + xz unpack
          # midway, so this overrides with enough headroom.
          resources {
            requests = { cpu = "10m", memory = "64Mi" }
            limits   = { cpu = "500m", memory = "256Mi" }
          }

          env {
            name  = "WEBUI_URL"
            value = var.webui_url
          }
          env {
            name  = "CLI_URL"
            value = var.cli_url
          }
          env {
            name  = "WEBUI_CLIENT_ID"
            value = local.webui_client_id
          }

          command = ["sh", "-eu", "-c", <<-EOT
            apk add --no-cache curl unzip zip xz >/dev/null

            # ── Volume layout guard ────────────────────────────────
            # 0.16 only migrates from 0.15.x (per UPGRADING/v0_16.md);
            # older state leaves the server unrecoverable. The sentinel
            # marks a volume this bootstrap has already initialised for
            # 0.16. Without it, an empty volume is a fresh install; a
            # non-empty one is either pre-0.16 state or a restore that
            # lost the marker — both need an operator decision, never an
            # automatic wipe, so the pod refuses to start.
            SENTINEL=/opt/stalwart-mail/.v016-bootstrapped
            if [ ! -f "$SENTINEL" ] && [ -n "$(find /opt/stalwart-mail/data /opt/stalwart-mail/etc -type f 2>/dev/null | head -n 1)" ]; then
              echo "[bootstrap] FATAL: data/etc present but no $SENTINEL." >&2
              echo "[bootstrap] Restored 0.16 volume: touch $SENTINEL on the volume and restart." >&2
              echo "[bootstrap] Pre-0.16 state: back it up, remove data/ and etc/ by hand, restart." >&2
              exit 1
            fi

            # ── Datastore config (idempotent overwrite) ────────────
            mkdir -p /opt/stalwart-mail/etc /opt/stalwart-mail/data/blobs
            cp /seed/config.json /opt/stalwart-mail/etc/config.json
            touch "$SENTINEL"
            # Only files with the wrong owner (chown -R rewrote every ctime).
            find /opt/stalwart-mail \( ! -user 1000 -o ! -group 1000 \) -exec chown 1000:1000 {} +

            # ── stalwart-cli binary ────────────────────────────────
            mkdir -p /shared/bin
            curl -sSLf "$CLI_URL" | tar -xJ -C /shared/bin --strip-components=0
            # Tarball usually unpacks to a dir with binary inside; handle both layouts.
            if [ ! -x /shared/bin/stalwart-cli ]; then
              mv /shared/bin/*/stalwart-cli /shared/bin/stalwart-cli
              rm -rf /shared/bin/*/
            fi
            chmod +x /shared/bin/stalwart-cli

            # ── WebUI bundle: download + sed + repackage ───────────
            mkdir -p /tmp/webui-src
            curl -sSLfo /tmp/webui.zip "$WEBUI_URL"
            unzip -qo /tmp/webui.zip -d /tmp/webui-src

            # Single literal `stalwart-webui` appears in the bundle's
            # JS twice (oauth.ts + api.ts), in both cases as a string.
            # Zitadel client_ids are URL-safe so the substitution is
            # straightforward sed.
            find /tmp/webui-src -name '*.js' -print0 \
              | xargs -0 sed -i "s/stalwart-webui/$WEBUI_CLIENT_ID/g"

            cd /tmp/webui-src && zip -qr /shared/webui.zip .
            ls -la /shared/ /shared/bin/
          EOT
          ]

          volume_mount {
            name       = "data"
            mount_path = "/opt/stalwart-mail"
          }
          volume_mount {
            name       = "shared"
            mount_path = "/shared"
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
          }
        }

        # Gated on OIDC: only meaningful when Stalwart validates Zitadel
        # tokens. alpine image matches the bootstrap init above (already
        # pulled); `apk add curl` brings ca-certificates for the HTTPS
        # issuer probe. Bounded ~5m (100 × 3s) then exits 0 regardless.
        dynamic "init_container" {
          for_each = local.oidc_set
          content {
            name  = "wait-zitadel"
            image = "alpine:3.22"

            security_context {
              run_as_user = 0
            }

            resources {
              requests = { cpu = "10m", memory = "16Mi" }
              limits   = { cpu = "100m", memory = "64Mi" }
            }

            env {
              name  = "ZITADEL_ISSUER"
              value = var.zitadel_issuer_url
            }

            command = ["sh", "-eu", "-c", <<-EOT
              apk add --no-cache curl >/dev/null
              URL="$ZITADEL_ISSUER/.well-known/openid-configuration"
              echo "[wait-zitadel] waiting up to ~5m for $URL"
              for i in $(seq 1 100); do
                if curl -sf -m 5 -o /dev/null "$URL"; then
                  echo "[wait-zitadel] Zitadel OIDC reachable — starting Stalwart"
                  exit 0
                fi
                sleep 3
              done
              echo "[wait-zitadel] still unreachable after ~5m — starting Stalwart anyway"
            EOT
            ]
          }
        }

        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }

        # ── Sidecar: applier ────────────────────────────────────
        # Regular container (not init-as-sidecar — k8s 1.29 feature
        # the kubernetes TF provider's `~> 2.0` constraint here
        # doesn't expose). Runs concurrently with main; waits for
        # stalwart's :8080 to be ready, then runs `stalwart-cli
        # apply` with the pinned recovery-admin creds. The plan is
        # idempotent (destroy + create at the head, then upserts),
        # so re-running every pod restart is fine. Sleeps forever
        # afterwards to keep the container up — without that the
        # Pod's RestartPolicy=Always would treat the exit as a
        # crash loop.
        container {
          name  = "applier"
          image = var.image

          # CLI takes credentials via env: STALWART_URL +
          # STALWART_USER + STALWART_PASSWORD (or STALWART_TOKEN).
          # Recovery admin user/password lives in two keys of the
          # mounted secret — read directly here.
          #
          # HOME points at /tmp because stalwart-cli's schema cache
          # uses `dirs::cache_dir()` (= $HOME/.cache on Linux) and
          # the container has no $HOME for uid 1000 — without this
          # the CLI tries to mkdir `/.cache/stalwart-cli/...` and
          # dies with `Permission denied (os error 13)` before any
          # JMAP call goes out.
          env {
            name  = "HOME"
            value = "/tmp"
          }
          env {
            name  = "STALWART_URL"
            value = "http://127.0.0.1:8080"
          }
          env {
            name = "STALWART_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.recovery_admin["enabled"].metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "STALWART_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.recovery_admin["enabled"].metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name  = "PRIMARY_DOMAIN"
            value = var.primary_domain
          }
          env {
            name  = "INGEST_ROUTE_NAMES"
            value = join(" ", [for k, _ in var.ingest_forwards : "ingest-${k}"])
          }
          env {
            name  = "INGEST_RELOAD"
            value = length(var.ingest_forwards) > 0 ? "1" : ""
          }
          env {
            # One `<friendly-id>|<target email>|<base64 update-line>`
            # entry per mail alias, space-joined — the applier looks up
            # each target email's live MailingList id and, if found,
            # drops the matching `create` and appends the decoded
            # update line with the id spliced in. Base64 avoids any
            # need to escape the JSON payload for shell/space-splitting.
            name = "MAIL_ALIAS_ENTRIES"
            value = join(" ", [
              for slug, a in var.mail_aliases :
              "list-${slug}|${a.name}@${a.domain}|${base64encode(local.mail_alias_update_lines[slug])}"
            ])
          }

          command = ["bash", "-eu", "-c", <<-EOT
            for i in $(seq 1 180); do
              if curl -sf -o /dev/null http://127.0.0.1:8080/.well-known/openid-configuration; then
                break
              fi
              sleep 2
            done

            # Delete stale create-only objects before the plan tries to
            # recreate them (no destroy-by-filter in `apply` ndjson, so a
            # re-apply with an existing object would primary-key-violate)
            # — handled here by name → id lookup. Covers the `smarthost`
            # MtaRoute, every `ingest-*` ingest-forward MtaRoute (names in
            # INGEST_ROUTE_NAMES), and the combined `ingest-forwards`
            # DATA-stage Sieve script.
            for rname in smarthost $${INGEST_ROUTE_NAMES:-}; do
              RID=$(/shared/bin/stalwart-cli query MtaRoute 2>/dev/null \
                | awk -v n="$rname" '$2==n {print $1; exit}') || true
              if [ -n "$${RID:-}" ]; then
                echo "[applier] removing stale MtaRoute '$rname' (id $RID)"
                /shared/bin/stalwart-cli delete MtaRoute --ids "$RID" \
                  || echo "[applier] $rname delete returned non-zero — proceeding anyway (RECONCILE-ERROR)"
              fi
            done
            SID=$(/shared/bin/stalwart-cli query SieveSystemScript 2>/dev/null \
              | awk '$2=="ingest-forwards" {print $1; exit}') || true
            if [ -n "$${SID:-}" ]; then
              echo "[applier] removing stale SieveSystemScript 'ingest-forwards' (id $SID)"
              /shared/bin/stalwart-cli delete SieveSystemScript --ids "$SID" \
                || echo "[applier] ingest-forwards delete returned non-zero — proceeding anyway (RECONCILE-ERROR)"
            fi

            # Domain idempotency. The plan declares
            # `create Domain dom-primary` with name=$PRIMARY_DOMAIN, but
            # Stalwart enforces uniqueness on Domain.name. On every
            # re-apply after the very first one, the create returns
            # `primaryKeyViolation` and the friendly id `dom-primary`
            # never resolves — which then cascades onto every plan
            # entry that references `#dom-primary`
            # (DkimSignature.dom-primary, SystemSettings.defaultDomainId).
            # Three ops fail loudly on every Stalwart pod start.
            #
            # Pre-step: query the existing Domain by name. If found,
            # rewrite the plan ndjson on the fly:
            #   - drop the `create Domain dom-primary` line entirely
            #   - replace every `#dom-primary` reference with the
            #     existing internal id
            # The remaining creates and updates resolve cleanly,
            # converging without the noisy 3-op failure.
            #
            # Plan file is mounted from a Secret (read-only); copy to
            # tmpfs first so sed -i can rewrite it.
            cp /seed/plan.ndjson /tmp/plan.ndjson

            # Domain idempotency (primary + every additional domain). Stalwart
            # enforces uniqueness on Domain.name, so on every re-apply after the
            # first, `create Domain` returns primaryKeyViolation and the friendly
            # id never resolves — cascading onto everything that references it
            # (DkimSignature.domainId, SystemSettings.defaultDomainId). For each
            # `create Domain` line, if a Domain with that name already exists,
            # drop the create and resolve its `#<friendly-id>` ref to the live id.
            /shared/bin/stalwart-cli query Domain 2>/dev/null \
              | awk 'NR>1 {print $1"\t"$2}' > /tmp/domains.tsv || true
            grep '"object":"Domain","value":' /tmp/plan.ndjson | while IFS= read -r line; do
              fid=$(printf '%s' "$line" | sed 's/.*"object":"Domain","value":{"\([^"]*\)":.*/\1/')
              name=$(printf '%s' "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
              did=$(awk -F'\t' -v n="$name" '$2==n {print $1; exit}' /tmp/domains.tsv)
              if [ -n "$did" ]; then
                echo "[applier] Domain '$name' already exists as id '$did' — skip create '$fid' + resolve refs"
                sed -i "/\"object\":\"Domain\",\"value\":{\"$fid\"/d" /tmp/plan.ndjson
                sed -i "s/#$fid/$did/g" /tmp/plan.ndjson
              fi
            done

            # DkimSignature idempotency. Stalwart auto-generates a DKIM signature
            # per Domain (rotation selectors `v1-rsa-<date>` etc.), so our
            # explicit `create DkimSignature` fails (invalidPatch / duplicate) on
            # any domain that already has one. Drop any create whose target
            # Domain (resolved to a real id by the block above) already has a
            # signature; keep creates for brand-new domains (ref still `#...`).
            SIGNED=$(/shared/bin/stalwart-cli query DkimSignature 2>/dev/null \
              | grep -o 'id: [a-z0-9]*' | awk '{print $2}' | sort -u)
            grep '"object":"DkimSignature","value":' /tmp/plan.ndjson | while IFS= read -r line; do
              fid=$(printf '%s' "$line" | sed 's/.*"object":"DkimSignature","value":{"\([^"]*\)":.*/\1/')
              did=$(printf '%s' "$line" | sed 's/.*"domainId":"\([^"]*\)".*/\1/')
              case "$did" in "#"*) continue ;; esac
              if printf '%s\n' "$SIGNED" | grep -qx "$did"; then
                echo "[applier] Domain id '$did' already has a DKIM signature — skip create '$fid'"
                sed -i "/\"object\":\"DkimSignature\",\"value\":{\"$fid\"/d" /tmp/plan.ndjson
              fi
            done

            # AllowedIp idempotency: the address is the primary key, so a
            # re-apply's create would fail with primaryKeyViolation. Drop
            # creates for addresses that already exist.
            ALLOWED=$(/shared/bin/stalwart-cli query AllowedIp 2>/dev/null \
              | awk 'NR>1 {print $2}')
            grep '"object":"AllowedIp","value":' /tmp/plan.ndjson | while IFS= read -r line; do
              fid=$(printf '%s' "$line" | sed 's/.*"object":"AllowedIp","value":{"\([^"]*\)":.*/\1/')
              addr=$(printf '%s' "$line" | sed 's/.*"address":"\([^"]*\)".*/\1/')
              if printf '%s\n' "$ALLOWED" | grep -qxF "$addr"; then
                echo "[applier] AllowedIp '$addr' already exists — skip create '$fid'"
                sed -i "/\"object\":\"AllowedIp\",\"value\":{\"$fid\"/d" /tmp/plan.ndjson
              fi
            done

            # Directory idempotency — same rewrite as Domain. The plan no
            # longer destroys the OIDC Directory (so its id stays stable and
            # the running server's directory cache never dangles), so on
            # every re-apply `create Directory dir-zitadel` would
            # primaryKeyViolate and `#dir-zitadel` would never resolve,
            # cascading onto `update Authentication directoryId=#dir-zitadel`
            # and leaving auth pointed at nothing. Query the existing Oidc
            # Directory; if present, drop its create line and resolve every
            # `#dir-zitadel` ref to the live id so Authentication keeps
            # pointing at the same directory across restarts.
            echo "[applier] checking for existing Oidc Directory"
            DIR_ID=$(/shared/bin/stalwart-cli query Directory 2>/dev/null \
              | awk '$2=="Oidc" {print $1; exit}') || true
            if [ -n "$${DIR_ID:-}" ]; then
              echo "[applier] Oidc Directory already exists as id '$DIR_ID' — rewriting plan to skip its create + resolve refs"
              sed -i '/"@type":"create","object":"Directory","value":{"dir-zitadel"/d' /tmp/plan.ndjson
              sed -i "s/#dir-zitadel/$DIR_ID/g" /tmp/plan.ndjson
            fi

            # MailingList idempotency. Unlike Domain (static name/
            # description, safe to skip-and-resolve forever), an
            # alias's `recipients` is expected to change on a later
            # apply — so instead of just skipping the stale create,
            # drop it and append the pre-rendered update line (see
            # `mail_alias_update_lines`) with the live id spliced in,
            # so recipient changes actually converge.
            for entry in $${MAIL_ALIAS_ENTRIES:-}; do
              fid="$${entry%%|*}"
              rest="$${entry#*|}"
              email="$${rest%%|*}"
              b64="$${rest#*|}"
              lid=$(/shared/bin/stalwart-cli query MailingList 2>/dev/null \
                | awk -v e="$email" '$2==e {print $1; exit}') || true
              if [ -n "$${lid:-}" ]; then
                echo "[applier] MailingList '$email' already exists as id '$lid' — replacing create '$fid' with an update"
                sed -i "/\"object\":\"MailingList\",\"value\":{\"$fid\"/d" /tmp/plan.ndjson
                # The rendered plan has no trailing newline (join("\n")) —
                # without this the appended line glues onto the last one and
                # the whole plan fails to parse ("trailing characters").
                [ -n "$(tail -c 1 /tmp/plan.ndjson)" ] && printf '\n' >> /tmp/plan.ndjson
                printf '%s' "$b64" | base64 -d | sed "s/__MAIL_ALIAS_ID__/$lid/" >> /tmp/plan.ndjson
              fi
            done

            # `--continue-on-error` so a JMAP filter rejection on
            # one destroy doesn't block the rest of the plan.
            # Updates are idempotent; creates may fail with
            # `alreadyExists` on a re-apply with no preceding destroy
            # — that's fine, the converged state is still right.
            if /shared/bin/stalwart-cli apply --file /tmp/plan.ndjson --continue-on-error; then
              echo "[applier] plan applied OK"
            else
              echo "[applier] RECONCILE-ERROR apply finished with errors — see above; main server stays up"
            fi

            # The webadmin (Application) is (re)created by the plan AFTER the
            # HTTP listener has already booted, so the listener never mounts it
            # on its own and every /admin + /account request 404s until an
            # explicit re-mount. `ReloadSettings` does NOT cover applications;
            # `UpdateApps` does. Trigger it after each apply so the WebUI is
            # always served at its urlPrefix.
            echo "[applier] mounting web applications on the live HTTP listener (UpdateApps)"
            /shared/bin/stalwart-cli create Action --json '{"@type":"UpdateApps"}' \
              || echo "[applier] UpdateApps returned non-zero — proceeding anyway (RECONCILE-ERROR)"

            # Settings-class objects (MtaStageData.script) are cached by
            # the running server at startup; the applier mutates them in
            # the DB AFTER the server is up, so the DATA-stage ingest
            # script binding stays inert until a reload. Trigger one when
            # ingest forwards are configured (same start-time-cache class
            # the OIDC Directory idempotency works around). Data objects
            # (Domains, MtaRoutes, accounts) take effect without it, so
            # the reload is skipped when there are no forwards.
            if [ -n "$${INGEST_RELOAD:-}" ]; then
              echo "[applier] reloading settings (ingest DATA-stage script binding)"
              /shared/bin/stalwart-cli create Action --json '{"@type":"ReloadSettings"}' \
                || echo "[applier] ReloadSettings returned non-zero — proceeding anyway (RECONCILE-ERROR)"
            fi

            sleep infinity
          EOT
          ]

          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          volume_mount {
            name       = "shared"
            mount_path = "/shared"
            read_only  = true
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
            read_only  = true
          }
          volume_mount {
            name       = "recovery-admin"
            mount_path = "/etc/recovery"
            read_only  = true
          }
        }

        # ── Main container ──────────────────────────────────────
        container {
          name  = "stalwart"
          image = var.image

          # Pod-level securityContext sets uid 1000; the auto-bootstrapped
          # listeners include :25 / :465 / :993 / :995 / :443 (all under
          # 1024) which can't be bound by uid 1000 without a capability.
          # Granting NET_BIND_SERVICE keeps the rest of the security
          # posture (non-root user, no privilege escalation) while
          # letting the listeners come up.
          security_context {
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          env {
            name  = "CONFIG_PATH"
            value = "/opt/stalwart-mail/etc/config.json"
          }

          # Recovery admin: pinned via env so the bootstrap-mode
          # one-time random password is replaced with our known one.
          # Same env keeps working in normal mode → fallback admin.
          env {
            name = "STALWART_RECOVERY_ADMIN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.recovery_admin["enabled"].metadata[0].name
                key  = "recovery_admin_env"
              }
            }
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

          volume_mount {
            name       = "data"
            mount_path = "/opt/stalwart-mail"
          }
          volume_mount {
            name       = "shared"
            mount_path = "/shared"
            read_only  = true
          }

          startup_probe {
            tcp_socket {
              port = local.http_target
            }
            period_seconds    = 5
            failure_threshold = 60
          }

          liveness_probe {
            tcp_socket {
              port = local.http_target
            }
            period_seconds    = 30
            failure_threshold = 3
          }

          readiness_probe {
            tcp_socket {
              port = local.http_target
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.stalwart["enabled"].metadata[0].name
          }
        }

        volume {
          name = "shared"
          empty_dir {}
        }

        volume {
          name = "seed"
          secret {
            secret_name = kubernetes_secret_v1.stalwart_seed["enabled"].metadata[0].name
          }
        }

        volume {
          name = "recovery-admin"
          secret {
            secret_name = kubernetes_secret_v1.recovery_admin["enabled"].metadata[0].name
          }
        }
      }
    }
  }
}
