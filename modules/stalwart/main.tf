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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    zitadel = {
      source  = "zitadel/zitadel"
      version = "~> 2.9"
    }
  }
}

# =============================================================================
# Stalwart 0.16 — declarative deployment via stalwart-cli apply
# =============================================================================
#
# 0.16 dropped TOML config. On disk lives only `config.json` (datastore
# definition); everything else (listeners, directories, accounts, OIDC)
# lives in the database and is loaded via `stalwart-cli apply` against
# the running server's JMAP API. Workflow:
#
#   1. ConfigMap renders config.json + plan.ndjson from TF templates.
#   2. Init container `bootstrap` writes config.json into the data PV
#      (idempotent), downloads stalwart-cli + the WebUI bundle, patches
#      the bundle's hard-coded `stalwart-webui` OAuth client_id with
#      our Zitadel application's client_id, places the patched zip on
#      a shared emptyDir.
#   3. Main container starts stalwart with STALWART_RECOVERY_ADMIN
#      pinned (env-var, doubles as fallback admin).
#   4. Sidecar `applier` (init container with restartPolicy: Always)
#      waits for :8080 ready and runs `stalwart-cli apply`. The plan
#      starts with destroy ops for the objects we own, then creates —
#      so re-running it (every pod restart) is idempotent.
#
# WebUI client_id obstacle — Stalwart's WebUI bundle bakes
# `stalwart-webui` literally at Vite build time. Zitadel auto-
# generates numeric client_ids and won't accept a literal one.
# Workaround: sed-replace the literal in the unpacked bundle JS,
# repackage, point Stalwart's Application.resource_url at file://
# instead of the upstream URL.


locals {
  instances = var.enabled ? toset(["enabled"]) : toset([])

  # Shorthand for the propagated null-label tag set.
  tags = module.label.tags

  # Match Stalwart's auto-bootstrapped default listeners — saves the
  # plan from having to manage NetworkListener objects (which is
  # awkward because destroying the http listener mid-apply would
  # kill the very connection the CLI is using). The pod gets
  # NET_BIND_SERVICE so uid 1000 can bind :25 directly.
  smtp_target = 25
  http_target = 8080

  # Whether to provision the Zitadel app + role + OIDC directory.
  # Off when zitadel_issuer_url is empty (Zitadel disabled at the
  # platform root); recovery-admin still works for WebUI access.
  oidc_enabled = var.enabled && var.zitadel_issuer_url != "" && var.zitadel_org_id != ""
  oidc_set     = local.oidc_enabled ? toset(["enabled"]) : toset([])

  # Random URL prefix that hides /admin and /account behind
  # obscurity. `mail.<domain>/<prefix>/admin` is the operator path;
  # `/<prefix>/account` is self-service (mostly empty for OIDC users
  # since password lives in Zitadel). Surfaced to the operator via
  # the `admin_url` / `account_url` outputs and the root cheatsheet.
  admin_path_prefix = var.enabled ? "/${random_password.admin_path["enabled"].result}" : ""
  webui_admin_url   = var.enabled ? "https://${var.hostname}${local.admin_path_prefix}/admin" : null
  webui_account_url = var.enabled ? "https://${var.hostname}${local.admin_path_prefix}/account" : null
  webui_url_prefixes = local.admin_path_prefix == "" ? {} : {
    "${local.admin_path_prefix}/admin"   = true
    "${local.admin_path_prefix}/account" = true
  }

  # DKIM key + DNS body. tls_private_key.public_key_pem is X.509
  # SubjectPublicKeyInfo PEM; DKIM TXT for k=rsa wants the
  # base64 of that SPKI body (between BEGIN/END headers, newlines
  # stripped). DNS record: `<selector>._domainkey.<domain>` TXT =
  # "v=DKIM1; k=rsa; p=<body>".
  dkim_pubkey_body = var.enabled ? trimspace(replace(replace(replace(
    tls_private_key.dkim["enabled"].public_key_pem,
    "-----BEGIN PUBLIC KEY-----", ""),
    "-----END PUBLIC KEY-----", ""),
  "\n", "")) : ""
  dkim_dns_value = var.enabled ? "v=DKIM1; k=rsa; p=${local.dkim_pubkey_body}" : ""
  dkim_dns_name  = "${var.dkim_selector}._domainkey"

  # Per-additional-domain pubkey body + DKIM TXT value. Same shape as
  # `dkim_pubkey_body` above, just iterated. Keyed by the operator-
  # supplied slug, which doubles as the friendly id in the Stalwart
  # apply plan (`dom-add-<slug>` / `dkim-add-<slug>`).
  additional_dkim_pubkey_body = {
    for slug, cfg in(var.enabled ? var.additional_domains : {}) :
    slug => trimspace(replace(replace(replace(
      tls_private_key.dkim_additional[slug].public_key_pem,
      "-----BEGIN PUBLIC KEY-----", ""),
      "-----END PUBLIC KEY-----", ""),
    "\n", ""))
  }
  additional_dkim_dns_value = {
    for slug, body in local.additional_dkim_pubkey_body :
    slug => "v=DKIM1; k=rsa; p=${body}"
  }

  spf_dns_value   = var.enabled && var.spf_authorized_ip != "" ? "v=spf1 ip4:${var.spf_authorized_ip} -all" : ""
  dmarc_dns_value = var.enabled && var.primary_domain != "" ? "v=DMARC1; p=${var.dmarc_policy}; rua=mailto:postmaster@${var.primary_domain}" : ""

  # Whether the module manages SPF/DKIM/DMARC TXT records directly
  # in Cloudflare (bypassing the per-domain yaml). Off when the
  # operator hasn't passed a zone id — keeps the module usable for
  # standalone testing without a Cloudflare zone.
  dns_records_enabled = var.enabled && var.cloudflare_zone_id != ""
  dns_records_set     = local.dns_records_enabled ? toset(["enabled"]) : toset([])

  # Per-record gates so an empty source value (e.g. operator hasn't
  # set spf_authorized_ip) skips just that record instead of breaking
  # the apply with an invalid TXT content.
  spf_record_set   = local.dns_records_enabled && local.spf_dns_value != "" ? toset(["enabled"]) : toset([])
  dmarc_record_set = local.dns_records_enabled && local.dmarc_dns_value != "" ? toset(["enabled"]) : toset([])

  # Whether to wire an outbound smart-host. Off (empty address) keeps
  # Stalwart on its default direct-MX route — which silently bounces
  # in this deployment because residential ISPs and Cloudflare Tunnel
  # both block outbound :25. With the relay configured, the queue
  # delivers via the relay's public IP + DKIM/SPF.
  smarthost_enabled = var.enabled && var.smarthost_address != ""

  # config.json is a single DataStore object — `@type` discriminator
  # picks the backend. 0.16 simplified the on-disk file to just this
  # one object; everything else (BlobStore, InMemoryStore, listeners,
  # directories, ...) is reachable as JMAP objects in the DB once
  # the datastore is loaded. SQLite path is a directory; Stalwart
  # creates the actual db files inside.
  config_json = jsonencode({
    "@type" = "Sqlite"
    # `path` is the actual SQLite file path — passed straight to
    # `rusqlite::Connection::open`. The docs use the word
    # "directory" but the code (`SqliteConnectionManager::file(path)`)
    # treats it as a file. The parent dir is created in the
    # bootstrap initContainer.
    path = "/opt/stalwart-mail/data/db.sqlite3"
  })

  # The OIDC client_id Zitadel auto-generated for the WebUI app.
  # Empty string when OIDC is off (the bundle will keep its default
  # `stalwart-webui` literal — works only against Stalwart-as-IDP).
  webui_client_id = local.oidc_enabled ? zitadel_application_oidc.stalwart["enabled"].client_id : "stalwart-webui"

  # Zitadel issues access tokens with `aud` set to the project_id, not
  # the client_id. Stalwart's `requireAudience` field is checked
  # against the `aud` claim — using the project_id here makes
  # validation pass. (`<client_id>` would mismatch.)
  webui_aud = local.oidc_enabled ? zitadel_project.stalwart["enabled"].id : ""

  # Plan rendered as NDJSON. Two-pass execution: destroys reverse
  # then creates/updates forward. Re-running the same plan on
  # restart is idempotent because the filtered destroys wipe the
  # objects we own (matched by description / name) before the
  # creates rebuild them. Update ops on singletons (SystemSettings,
  # Authentication, Http) are idempotent by definition.
  #
  # NetworkListener is intentionally NOT in the plan: the apply runs
  # against http://127.0.0.1:8080, which is one of Stalwart's
  # auto-bootstrapped default listeners. Destroying it mid-apply
  # would kill the very connection the CLI is using. Stalwart's
  # defaults (smtp 25, http 8080, plus 465/993/995/4190/443 that
  # bind iff NET_BIND_SERVICE is granted to the pod) cover what we
  # need; the Service routes :25 and :8080 outward.
  plan_lines = concat(
    # ── Destroy pass (filtered to objects we own) ─────────────────
    # Each object kind exposes a different set of filterable fields
    # (Stalwart's JMAP query callbacks register them per type) and
    # rejects unknown filter properties at parse time. Empirically:
    #   - Domain accepts `name`
    #   - Account accepts `@type` (per the canonical example plan)
    #   - Directory accepts `@type` (variants Internal/Ldap/Sql/Oidc)
    #   - Application has no documented filterable property — relying
    #     on the empty-filter destroy-all (we only ever own one).
    # Stalwart-cli is invoked with `--continue-on-error` so any
    # surprise filter rejection on a fresh JMAP shape doesn't block
    # the create/update pass that follows.
    [
      # Application destroy is fine — no foreign-key dependents and
      # the resourceUrl is the only thing that ever changes here.
      jsonencode({ "@type" = "destroy", object = "Application" }),
      # Domain is intentionally NOT destroyed: DkimSignature rows and
      # the SystemSettings.defaultDomainId reference link to it, and
      # `destroy Domain` fails with `objectIsLinked` once those exist.
      # On re-apply the `create Domain` below will fail with
      # `primaryKeyViolation` (which `--continue-on-error` swallows);
      # since Domain shape is just `{name, description}` and never
      # changes after the first run, this is harmless.
    ],
    # Directory is intentionally NOT destroyed (mirrors the Domain policy
    # above). The OIDC Directory keeps a stable internal id across applies,
    # so Authentication never re-points at a freshly-created id and
    # Stalwart's start-time directory cache never dangles — the exact
    # regression that broke OIDC login after every pod restart / node
    # reboot (the applier used to destroy + recreate the Directory each run,
    # invalidating the id the running server had cached). On re-apply the
    # applier rewrites the plan to skip `create Directory dir-zitadel` and
    # resolve `#dir-zitadel` to the existing id (see the Directory-
    # idempotency pre-step in the applier command). First apply still
    # creates it; the create simply never runs a second time.

    # ── Create pass: parents-first ────────────────────────────────
    [
      # Local file replaces upstream URL so Stalwart serves the
      # patched bundle (bundle's `stalwart-webui` literal sed-
      # replaced with the Zitadel-issued client_id at init).
      jsonencode({
        "@type" = "create"
        object  = "Application"
        value = {
          app-webui = {
            description = "Stalwart Web Interface"
            enabled     = true
            resourceUrl = "file:///shared/webui.zip"
            # Stalwart's `Map<String>` serializes as an object whose
            # keys are the elements and values are `true` — not as a
            # JSON array. Same form below for OidcDirectory.requireScopes.
            #
            # The /admin and /account paths sit behind a random URL
            # prefix so the Stalwart UI doesn't surface on the public
            # root of mail.<domain> (which serves Roundcube). The
            # bundle's React Router uses `<base href>` from the
            # served index.html, so urlPrefix at any depth works
            # without code changes.
            urlPrefix = local.webui_url_prefixes
          }
        }
      }),

      # Mail domain. defaultDomainId on SystemSettings is patched
      # in the update pass below, against this same #-ref.
      jsonencode({
        "@type" = "create"
        object  = "Domain"
        value = {
          dom-primary = {
            name        = var.primary_domain
            description = "Primary mail domain (managed by terraform-minikube-platform)."
          }
        }
      }),
    ],

    # ── OIDC bits — only when zitadel is wired in ─────────────────
    local.oidc_enabled ? [
      # External IdP for end-user authentication. Stalwart validates
      # bearer tokens by calling Zitadel /userinfo. usernameDomain
      # appends @<primary_domain> to bare claim values so a Zitadel user
      # `alice` becomes `alice@<primary_domain>` mailbox. claimGroups
      # populates Stalwart group memberships, which carry roles via
      # the Group entity created below.
      #
      # `requireScopes` deliberately omitted — Stalwart enforces it
      # against the `scope` claim *embedded in the access_token JWT*,
      # but Zitadel 2.x's default JWT access_token does not carry a
      # `scope` claim (scopes are tracked at /introspect / /userinfo
      # only). Setting `requireScopes:{email:true,...}` therefore
      # produced `Missing required scope 'email', present scopes: []`
      # → 401 on every login. The actual email/profile/groups data
      # comes from `/userinfo` via `claimEmail` / `claimName` /
      # `claimGroups` — those are always populated correctly when the
      # WebUI requested the right scopes at /authorize.
      jsonencode({
        "@type" = "create"
        object  = "Directory"
        value = {
          dir-zitadel = {
            "@type"         = "Oidc"
            description     = "Zitadel SSO"
            issuerUrl       = var.zitadel_issuer_url
            requireAudience = local.webui_aud
            # Empty Map<String> — explicitly override Stalwart's default
            # `requireScopes = {openid, email}`. Zitadel's JWT access_token
            # doesn't carry a `scope` claim at all, so any non-empty
            # requirement here fails token validation with `present
            # scopes: []`. The actual email/groups data comes through
            # /userinfo via `claimEmail` / `claimGroups`, not through
            # the access_token's scope claim.
            requireScopes  = {}
            claimUsername  = "preferred_username"
            usernameDomain = var.primary_domain
            claimName      = "name"
            claimGroups    = "groups"
          }
        }
      }),

      # Authentication singleton — point at the OIDC directory.
      # Admin role for OIDC users is intentionally NOT modelled
      # as a Stalwart Group with `roles: {@type:Admin}` here:
      # GroupAccount.roles is the `Roles` enum (Default | Custom)
      # and has no `Admin` variant (that's UserRoles only). v1
      # admin path is `STALWART_RECOVERY_ADMIN` (env-pinned, password
      # in Secret); operator logs in as `admin` for any admin task,
      # OIDC users land as regular mailbox principals. Wiring an
      # OIDC-claim → Custom role mapping is a follow-up.
      jsonencode({
        "@type" = "update"
        object  = "Authentication"
        value = {
          directoryId = "#dir-zitadel"
        }
      }),

      # Minimise the access-token positive cache. Stalwart's `Cache`
      # struct caches access-token → user-info lookups by capacity
      # only (LRU eviction, no TTL). When an operator grants a new
      # OIDC role in Zitadel, an existing cached access_token still
      # resolves to the pre-grant identity until LRU pressure
      # eventually evicts it OR the pod restarts.
      #
      # Stalwart validation refuses values below 2048 ("must be at
      # least 2048" — verified at apply 2026-05-08), so we cap at
      # the floor. Combined with the 5-minute access-token lifetime
      # set on the Zitadel side (`services.zitadel.oidc_settings`),
      # an entry can stay cached at most one token-lifetime window
      # before the OIDC consumer rotates to a fresh token (and a
      # fresh cache key) — bounding role-grant staleness to ≤5min
      # without per-request `/userinfo` round-trips.
      jsonencode({
        "@type" = "update"
        object  = "Cache"
        value = {
          accessTokens = 2048
        }
      }),
    ] : [],

    # ── Outbound smart host (when configured) ─────────────────────
    # MtaRoute Relay variant. The pre-existing built-in routes `local`
    # and `mx` are NOT touched — we add a route named `smarthost`; the
    # single combined MtaOutboundStrategy update further below flips the
    # default else-branch from `'mx'` to `'smarthost'` so non-local mail
    # goes through the relay. The applier sidecar deletes any stale
    # MtaRoute named `smarthost` before this create runs (see the
    # applier command), so plan re-applies are idempotent.
    local.smarthost_enabled ? [
      jsonencode({
        "@type" = "create"
        object  = "MtaRoute"
        value = {
          smarthost = {
            "@type"           = "Relay"
            name              = "smarthost"
            description       = "Outbound relay (residential ISPs and Cloudflare Tunnel block direct :25)."
            address           = var.smarthost_address
            port              = var.smarthost_port
            protocol          = "smtp"
            implicitTls       = var.smarthost_implicit_tls
            allowInvalidCerts = var.smarthost_allow_invalid_certs
            authUsername      = var.smarthost_username != "" ? var.smarthost_username : null
            authSecret = var.smarthost_username != "" ? {
              "@type" = "Value"
              value   = var.smarthost_password
              } : {
              "@type" = "None"
            }
          }
        }
      }),
    ] : [],

    # ── SMTP-push ingest forwards (machine intake of mailbox mail) ─
    # Per `var.ingest_forwards` entry: a `redirect :copy` rule (every
    # message whose SMTP envelope recipient is `address` → a synthetic
    # ingest address) lives in ONE combined DATA-stage Sieve script
    # (`ingest-forwards`), and the synthetic domain is pinned to an
    # in-cluster SMTP listener via an MtaRoute Relay. `:copy` keeps the
    # original in the mailbox as archive; a down listener means standard
    # SMTP queue+retry. The Sieve uses `envelope :is "to"` (the SMTP
    # RCPT TO) not the `To:` header — bounces/DSNs carry the original
    # sender in the header, only the envelope names our mailbox. Proven
    # to coexist with the spam filter (it stays enabled; both run at the
    # DATA stage). The script lives in ONE object because the DATA stage
    # runs a single script (`MtaStageData.script`); per-forward scripts
    # would never fire. CRITICAL: the running server caches MtaStageData
    # at startup, so the applier MUST `ReloadSettings` after this apply
    # for the binding to take effect (see the applier command) — same
    # start-time-cache class as the OIDC Directory id.
    [
      for key, f in var.ingest_forwards :
      jsonencode({
        "@type" = "create"
        object  = "MtaRoute"
        value = {
          "ingest-${key}" = {
            "@type"           = "Relay"
            name              = "ingest-${key}"
            description       = "SMTP-push ingest: ${f.synthetic_domain} delivers to an in-cluster listener."
            address           = f.smtp_host
            port              = f.smtp_port
            protocol          = "smtp"
            implicitTls       = false
            allowInvalidCerts = false
            authSecret        = { "@type" = "None" }
          }
        }
      })
    ],

    # Combined DATA-stage Sieve script (one `redirect :copy` per
    # forward) + bind it into the DATA stage. Only when ≥1 forward.
    length(var.ingest_forwards) > 0 ? [
      jsonencode({
        "@type" = "create"
        object  = "SieveSystemScript"
        value = {
          "sieve-ingest-forwards" = {
            name     = "ingest-forwards"
            isActive = true
            contents = "require [\"envelope\", \"copy\"];\n${join("", [
              for key, f in var.ingest_forwards :
              "if envelope :is \"to\" \"${f.address}\" {\n  redirect :copy \"ingest@${f.synthetic_domain}\";\n}\n"
            ])}"
          }
        }
      }),
      # Bind the script into the SMTP DATA stage. `script` is an
      # Expression object (`{match, else}`), not a bare string — the
      # unconditional `else` names the script (default is the
      # expression `false` = run nothing). `enableSpamFilter` is left
      # untouched; both run at the DATA stage.
      jsonencode({
        "@type" = "update"
        object  = "MtaStageData"
        value = {
          script = {
            match = {}
            else  = "'ingest-forwards'"
          }
        }
      }),
    ] : [],

    # Single combined outbound routing strategy. Keeps the upstream
    # `is_local_domain → 'local'` branch, pins each synthetic ingest
    # domain to its route, and falls back to the smart host (or plain
    # MX when no smart host is configured).
    (local.smarthost_enabled || length(var.ingest_forwards) > 0) ? [
      jsonencode({
        "@type" = "update"
        object  = "MtaOutboundStrategy"
        value = {
          route = {
            match = merge(
              { "0" = { if = "is_local_domain(rcpt_domain)", then = "'local'" } },
              { for i, key in keys(var.ingest_forwards) :
                tostring(i + 1) => {
                  if   = "rcpt_domain == '${var.ingest_forwards[key].synthetic_domain}'"
                  then = "'ingest-${key}'"
                }
              }
            )
            else = local.smarthost_enabled ? "'smarthost'" : "'mx'"
          }
        }
      }),
    ] : [],

    # ── DKIM signing key for the primary domain ───────────────────
    # tls_private_key in TF state stays stable across applies; the
    # `--continue-on-error` swallows `alreadyExists` on re-apply so
    # the key in Stalwart is set once and never rotated by accident.
    # Public key body is also TF-derived and exported via
    # `dkim_dns_value` for the operator to drop into the domain yaml.
    var.enabled ? [
      jsonencode({
        "@type" = "create"
        object  = "DkimSignature"
        value = {
          dkim-primary = {
            "@type"          = "Dkim1RsaSha256"
            domainId         = "#dom-primary"
            selector         = var.dkim_selector
            canonicalization = "relaxed/relaxed"
            stage            = "active"
            headers          = ["From", "To", "Subject", "Date", "Message-ID", "MIME-Version"]
            report           = false
            privateKey = {
              "@type" = "Value"
              value   = tls_private_key.dkim["enabled"].private_key_pem
            }
          }
        }
      }),
    ] : [],

    # ── Additional submission-only mail domains ───────────────────
    # One Domain + DkimSignature pair per entry in
    # `var.additional_domains`. Friendly ids `dom-add-<slug>` and
    # `dkim-add-<slug>` so multiple additional domains don't collide.
    # Domain destroy is skipped same as primary (objectIsLinked when
    # the DkimSignature references it); `--continue-on-error`
    # swallows the `primaryKeyViolation` on re-apply since neither
    # object mutates once created.
    var.enabled ? [
      for slug, cfg in var.additional_domains : jsonencode({
        "@type" = "create"
        object  = "Domain"
        value = {
          "dom-add-${slug}" = {
            name        = cfg.name
            description = "Additional mail domain ${cfg.name} (managed by terraform-minikube-platform)."
          }
        }
      })
    ] : [],

    var.enabled ? [
      for slug, cfg in var.additional_domains : jsonencode({
        "@type" = "create"
        object  = "DkimSignature"
        value = {
          "dkim-add-${slug}" = {
            "@type"          = "Dkim1RsaSha256"
            domainId         = "#dom-add-${slug}"
            selector         = cfg.dkim_selector
            canonicalization = "relaxed/relaxed"
            stage            = "active"
            headers          = ["From", "To", "Subject", "Date", "Message-ID", "MIME-Version"]
            report           = false
            privateKey = {
              "@type" = "Value"
              value   = tls_private_key.dkim_additional[slug].private_key_pem
            }
          }
        }
      })
    ] : [],

    # ── Stdout tracer ─────────────────────────────────────────────
    # Without a Tracer object Stalwart's default `kubectl logs` view
    # stays empty (no startup banner, no auth events, no SMTP
    # decisions). Wipe-and-create on every apply so subsequent
    # applies converge to the same shape; level=info is enough for
    # ops day-to-day, switch to debug/trace when chasing an OIDC
    # token-validation problem.
    [
      jsonencode({ "@type" = "destroy", object = "Tracer" }),
      jsonencode({
        "@type" = "create"
        object  = "Tracer"
        value = {
          tr-stdout = {
            "@type"   = "Stdout"
            enable    = true
            level     = "info"
            lossy     = false
            ansi      = false
            multiline = false
          }
        }
      }),
    ],

    # ── Update singletons (always idempotent) ─────────────────────
    [
      jsonencode({
        "@type" = "update"
        object  = "SystemSettings"
        value = {
          defaultDomainId = "#dom-primary"
          defaultHostname = var.hostname
        }
      }),
      jsonencode({
        "@type" = "update"
        object  = "Http"
        value = {
          useXForwarded = true
        }
      }),
      jsonencode({
        "@type" = "update"
        object  = "BlobStore"
        value   = { "@type" = "Default" }
      }),
      jsonencode({
        "@type" = "update"
        object  = "InMemoryStore"
        value   = { "@type" = "Default" }
      }),
      jsonencode({
        "@type" = "update"
        object  = "SearchStore"
        value   = { "@type" = "Default" }
      }),
    ],
  )

  plan_ndjson = join("\n", local.plan_lines)
}

# Module-tier label, chained off `var.context` (root passes
# `module.platform_label.context` from `_label.tf`).
module "label" {
  source = "git::https://github.com/rromenskyi/terraform-null-label.git?ref=v0.1.0"

  context   = var.context
  namespace = var.namespace
  name      = "stalwart"
  tags = {
    "app.kubernetes.io/component" = "stalwart"
  }
}

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
    "https://${var.hostname}${local.admin_path_prefix}/admin/oauth/callback",
    "https://${var.hostname}${local.admin_path_prefix}/account/oauth/callback",
  ]
  post_logout_redirect_uris = [
    "https://${var.hostname}${local.admin_path_prefix}/admin/login",
    "https://${var.hostname}${local.admin_path_prefix}/account/login",
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

# ── Mail-auth DNS records (SPF / DKIM / DMARC) ───────────────────────────────
#
# Emitted directly as `cloudflare_record` resources rather than going
# through `config/domains/<x>.yaml` because the values are TF-derived
# (DKIM body comes from `tls_private_key.dkim`, SPF/DMARC from module
# vars). Hand-pasting the rendered DKIM body into yaml every key
# rotation would be busy-work; this keeps the source-of-truth single.
resource "cloudflare_dns_record" "spf" {
  for_each = local.spf_record_set

  zone_id = var.cloudflare_zone_id
  # v5 requires FQDN — `@` is no longer accepted.
  name    = var.primary_domain
  type    = "TXT"
  content = local.spf_dns_value
  proxied = false
  ttl     = 300
  comment = "SPF — managed by modules/stalwart (terraform-minikube-platform)"
}

resource "cloudflare_dns_record" "dkim" {
  for_each = local.dns_records_set

  zone_id = var.cloudflare_zone_id
  name    = "${local.dkim_dns_name}.${var.primary_domain}"
  type    = "TXT"
  content = local.dkim_dns_value
  proxied = false
  ttl     = 300
  comment = "DKIM — managed by modules/stalwart (terraform-minikube-platform)"
}

resource "cloudflare_dns_record" "dmarc" {
  for_each = local.dmarc_record_set

  zone_id = var.cloudflare_zone_id
  name    = "_dmarc.${var.primary_domain}"
  type    = "TXT"
  content = local.dmarc_dns_value
  proxied = false
  ttl     = 300
  comment = "DMARC — managed by modules/stalwart (terraform-minikube-platform)"
}

# DKIM RSA key — rendered into the bootstrap plan's DkimSignature.
# Stable: tls_private_key keeps the same value across applies, so the
# public key in DNS doesn't churn. Rotation = taint this resource +
# bump the selector var.
resource "tls_private_key" "dkim" {
  for_each = local.instances

  algorithm = "RSA"
  rsa_bits  = 2048
}

# Per-additional-domain DKIM keypair. One RSA-2048 pair per entry in
# `var.additional_domains`; engine pairs it with a Stalwart
# DkimSignature object referencing that domain. Stable in TF state —
# never rotated by accident.
resource "tls_private_key" "dkim_additional" {
  for_each = var.enabled ? var.additional_domains : {}

  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "random_password" "recovery_admin" {
  for_each = local.instances

  length  = 32
  special = false
}

# Random URL prefix in front of /admin and /account so the operator-only
# Stalwart UI sits at `mail.<domain>/<random>/admin` etc. The webmail
# (Roundcube) lives at the root and is the only path normal users
# touch; admin lives behind URL-obscurity so unauthenticated drive-by
# scans don't even hit the OIDC-protected admin login screen. Stable
# across applies (no triggers), changes only when the resource is
# explicitly tainted.
resource "random_password" "admin_path" {
  for_each = local.instances

  length  = 16
  special = false
  upper   = false
}

resource "kubernetes_secret_v1" "recovery_admin" {
  for_each = local.instances

  metadata {
    name      = "stalwart-recovery-admin"
    namespace = var.namespace
    labels    = local.tags
  }

  data = {
    username = "admin"
    password = random_password.recovery_admin["enabled"].result
    # Ready-to-paste env var format (`username:password`) — main
    # container references this key directly.
    recovery_admin_env = "admin:${random_password.recovery_admin["enabled"].result}"
  }
}

# ── Secret with config.json + plan.ndjson ────────────────────────────────────
#
# Routed via Secret (not ConfigMap) because plan.ndjson can carry
# `var.smarthost_password` plaintext when the operator uses an
# AUTH-required outbound relay. ConfigMap data lands in etcd as
# plaintext; Secret data is base64 + etcd-encryption-at-rest when the
# cluster is configured for it (k3s enables it by default since
# 1.20). The applier sidecar reads the same files at the same mount
# path — only the volume source differs.
resource "kubernetes_secret_v1" "stalwart_seed" {
  for_each = local.instances

  metadata {
    name      = "stalwart-seed"
    namespace = var.namespace
    labels    = local.tags
  }

  data = {
    "config.json" = local.config_json
    "plan.ndjson" = local.plan_ndjson
  }
}

# ── hostPath storage for /opt/stalwart-mail (data + etc) ──────────────────────

resource "kubernetes_persistent_volume_v1" "stalwart" {
  for_each = local.instances

  metadata {
    name   = "platform-stalwart-data"
    labels = local.tags
  }

  spec {
    capacity = {
      storage = "10Gi"
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        path = "${var.volume_base_path}/${var.namespace}/stalwart"
        type = "DirectoryOrCreate"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "stalwart" {
  for_each = local.instances

  metadata {
    name      = "stalwart-data"
    namespace = var.namespace
    labels    = local.tags
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.stalwart["enabled"].metadata[0].name

    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

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
  for_each = local.instances

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
  for_each = local.instances

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

            # ── One-time wipe before first 0.16 boot ───────────────
            # 0.16 only migrates from 0.15.x (per UPGRADING/v0_16.md).
            # Anything older — including the 0.10.5 TOML state we used
            # to run — is unsupported and will leave the server in an
            # unrecoverable state. The platform's mail PVC has no real
            # mailboxes yet (we never made it past the wizard), so a
            # wipe is the correct conversion. Sentinel file gates the
            # operation: present after the first 0.16 bootstrap, absent
            # on a v0.10-era hostPath.
            SENTINEL=/opt/stalwart-mail/.v016-bootstrapped
            if [ ! -f "$SENTINEL" ]; then
              echo "[bootstrap] no v0.16 sentinel found — wiping legacy data dir before first boot"
              rm -rf /opt/stalwart-mail/data /opt/stalwart-mail/etc
            fi

            # ── Datastore config (idempotent overwrite) ────────────
            mkdir -p /opt/stalwart-mail/etc /opt/stalwart-mail/data/blobs
            cp /seed/config.json /opt/stalwart-mail/etc/config.json
            touch "$SENTINEL"
            chown -R 1000:1000 /opt/stalwart-mail

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
                  || echo "[applier] $rname delete returned non-zero — proceeding anyway"
              fi
            done
            SID=$(/shared/bin/stalwart-cli query SieveSystemScript 2>/dev/null \
              | awk '$2=="ingest-forwards" {print $1; exit}') || true
            if [ -n "$${SID:-}" ]; then
              echo "[applier] removing stale SieveSystemScript 'ingest-forwards' (id $SID)"
              /shared/bin/stalwart-cli delete SieveSystemScript --ids "$SID" \
                || echo "[applier] ingest-forwards delete returned non-zero — proceeding anyway"
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

            # `--continue-on-error` so a JMAP filter rejection on
            # one destroy doesn't block the rest of the plan.
            # Updates are idempotent; creates may fail with
            # `alreadyExists` on a re-apply with no preceding destroy
            # — that's fine, the converged state is still right.
            if /shared/bin/stalwart-cli apply --file /tmp/plan.ndjson --continue-on-error; then
              echo "[applier] plan applied OK"
            else
              echo "[applier] apply finished with errors — see above; main server stays up"
            fi

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
                || echo "[applier] ReloadSettings returned non-zero — proceeding anyway"
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

# ── SMTP relay forwarder ──────────────────────────────────────────────────────
#
# Tiny socat pod whose only job is to listen on the WireGuard interface
# address and forward to the in-cluster Stalwart SMTP Service. Runs with
# hostNetwork=true because it MUST bind to a specific host IP (the WG
# address); doing this in the Stalwart pod itself would put Stalwart's
# HTTP listener on every host interface as a side-effect, which we
# explicitly want to avoid.
resource "kubernetes_deployment_v1" "stalwart_smtp_relay" {
  for_each = local.instances

  metadata {
    name      = "stalwart-smtp-relay"
    namespace = var.namespace
    labels    = merge(local.tags, { app = "stalwart-smtp-relay" })
  }

  spec {
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "stalwart-smtp-relay" }
    }

    template {
      metadata {
        labels = merge(local.tags, { app = "stalwart-smtp-relay" })
      }

      spec {
        host_network = true
        dns_policy   = "ClusterFirstWithHostNet"

        # `var.smtp_relay_listen_ip` may resolve only on a specific
        # node (e.g. when the operator's deployment binds the inbound
        # forwarder to an interface that lives on one host). Pin
        # there via `var.node_selector`; without the selector and on
        # a multi-node cluster, the scheduler can land this pod
        # where the bind address doesn't exist and socat fails at
        # start with "Cannot assign requested address".
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

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

        container {
          name  = "socat"
          image = "alpine/socat:1.8.0.0"

          args = [
            "TCP-LISTEN:25,bind=${var.smtp_relay_listen_ip},fork,reuseaddr",
            "TCP:stalwart-smtp.${var.namespace}.svc.cluster.local:25",
          ]

          security_context {
            run_as_user                = 0
            allow_privilege_escalation = false
            capabilities {
              add  = ["NET_BIND_SERVICE"]
              drop = ["ALL"]
            }
          }

          resources {
            requests = { cpu = "10m", memory = "16Mi" }
            limits   = { cpu = "100m", memory = "32Mi" }
          }
        }
      }
    }
  }
}

