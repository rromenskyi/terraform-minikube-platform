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
  # Base origin the admin/account WebUI + its OIDC callbacks live under. With a
  # dedicated `admin_hostname` (served LAN-only by the socat admin proxy) the UI
  # sits at that host's root — no obscurity prefix needed since it isn't public.
  # Falls back to the prefix-on-mail-host model when no admin_hostname is set.
  admin_origin      = var.enabled ? (var.admin_hostname != "" ? "https://${var.admin_hostname}" : "https://${var.hostname}${local.admin_path_prefix}") : ""
  webui_admin_url   = var.enabled ? "${local.admin_origin}/admin" : null
  webui_account_url = var.enabled ? "${local.admin_origin}/account" : null
  # URL prefixes the webadmin Application is served at. With a dedicated
  # LAN-only `admin_hostname` the UI sits at bare /admin + /account (no
  # obscurity prefix needed off the public internet); otherwise it hides behind
  # the random prefix on the public mail host.
  webui_url_prefixes = var.admin_hostname != "" ? {
    "/admin"   = true
    "/account" = true
    } : (local.admin_path_prefix == "" ? {} : {
      "${local.admin_path_prefix}/admin"   = true
      "${local.admin_path_prefix}/account" = true
  })

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

  # Domain FQDN -> plan friendly-id ref, for `var.mail_aliases[*].domain`.
  # Indexing this with an unmanaged domain errors at plan time, which is the
  # intended fail-fast for a typo'd alias domain.
  mail_alias_domain_refs = merge(
    { (var.primary_domain) = "#dom-primary" },
    { for slug, cfg in var.additional_domains : cfg.name => "#dom-add-${slug}" },
  )

  # Pre-rendered `update MailingList` line per `var.mail_aliases` entry,
  # `id` left as a literal placeholder the applier splices in at
  # runtime once it has looked up the existing object's real id (see
  # the mail-alias idempotency step below) — Terraform already knows
  # every other field statically, so only the id needs a runtime value.
  mail_alias_update_lines = {
    for slug, a in(var.enabled ? var.mail_aliases : {}) :
    slug => jsonencode({
      "@type" = "update"
      object  = "MailingList"
      id      = "__MAIL_ALIAS_ID__"
      value = {
        description = a.description != "" ? a.description : "Mail alias (managed by terraform-minikube-platform)."
        recipients  = { for r in a.recipients : r => true }
      }
    })
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

    # ── Auto-ban exemptions ───────────────────────────────────────
    # Kubernetes probes and SNAT'd client traffic reach Stalwart from
    # cluster-internal addresses; the fail2ban heuristic reads probe
    # bursts as "port scanning" and bans the shared SNAT source, which
    # silently locks EVERY IMAP/SMTP client out (2026-07-09 outage:
    # 100.72.0.1 banned indefinitely, every client dropped without a
    # banner). AllowedIp entries are exempt from auto-ban. Create-only
    # like Domain — the duplicate create on re-apply fails with
    # primaryKeyViolation, which --continue-on-error swallows.
    [
      for i, cidr in var.allowed_networks : jsonencode({
        "@type" = "create"
        object  = "AllowedIp"
        value = {
          ("allow-net-${i}") = {
            address = cidr
            reason  = "cluster-internal network — kube probes/SNAT sources must never be auto-banned (managed by terraform-minikube-platform)"
          }
        }
      })
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
    # message whose SMTP envelope recipient matches ANY of `addresses`
    # → a synthetic ingest address) lives in ONE combined DATA-stage Sieve script
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
            # VERP attribution: Stalwart strips subaddressing
            # (`mail+<token>@`) BEFORE the DATA-stage Sieve, so the
            # token is gone from the envelope (`:detail`/`:all` return
            # the bare address — verified). The relay (Postfix) records
            # the real envelope recipient in its `Received: ... for
            # <mail+<token>@dom>` clause, added before Stalwart, so we
            # recover it from there into `X-Original-To` for the
            # listener. `${2}` is the Sieve match var (TF-escaped
            # `$${2}`); the `header :matches` test no-ops (no header
            # added) when no `for` clause is present, so plain mail
            # without a token still forwards cleanly.
            contents = "require [\"envelope\", \"copy\", \"editheader\", \"variables\"];\n${join("", [
              for key, f in var.ingest_forwards :
              "if anyof(${join(", ", [for a in f.addresses : "envelope :is \"to\" \"${a}\""])}) {\n  if header :matches \"Received\" \"*for <*>*\" {\n    addheader \"X-Original-To\" \"$${2}\";\n  }\n  redirect :copy \"ingest@${f.synthetic_domain}\";\n}\n"
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

    # Trust in-cluster senders: exclude connections matching operator-listed
    # IP regexes or EHLO hostnames from the DATA-stage spam filter. Mail
    # delivered straight to :25 from a pod (e.g. Alertmanager) fails public
    # SPF/DMARC and would otherwise be scored as spam and filed to Junk.
    # `matches(regex, value)` (pattern FIRST per Stalwart's signature) rather
    # than a CIDR builtin — 0.16.x has no CIDR expression function
    # (`is_ip_in_cidr` only landed post-0.16.3). JMAP `update` is a
    # per-property PATCH, so this coexists with the `script` update above.
    # Keeps the stock default (`is_empty(authenticated_as)` = filter
    # unauthenticated sessions) and ANDs in one exclusion per entry.
    length(var.internal_trusted_ip_patterns) + length(var.internal_trusted_helo_domains) > 0 ? [
      jsonencode({
        "@type" = "update"
        object  = "MtaStageData"
        value = {
          enableSpamFilter = {
            match = {}
            else = join("", concat(
              ["is_empty(authenticated_as)"],
              [for p in var.internal_trusted_ip_patterns : " && !matches('${p}', remote_ip)"],
              [for h in var.internal_trusted_helo_domains : " && helo_domain != '${h}'"],
            ))
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

    # ── Inbound mail aliases ────────────────────────────────────────
    # One MailingList per `var.mail_aliases` entry — Stalwart's own
    # idiom for a plain forward-only alias (a list with real recipients
    # but no subscribers), used instead of a dedicated Account so the
    # alias needs no login/credentials of its own. `recipients` accepts
    # any valid address, local or external. Friendly id `list-<slug>`.
    # Never destroyed (same reasoning as Domain above — nothing to
    # objectIsLinked on yet, but wiping-and-recreating on every apply
    # would also nuke any MailingList the operator created by hand,
    # e.g. hand-made distribution lists such as hello@/corp@). The applier's idempotency pass converts a `create` whose
    # target address already exists into an `update` instead, so
    # `recipients` changes on a later apply actually take effect —
    # unlike Domain's static name/description, an alias's recipient
    # list is expected to change over time.
    var.enabled ? [
      for slug, a in var.mail_aliases : jsonencode({
        "@type" = "create"
        object  = "MailingList"
        value = {
          "list-${slug}" = {
            name        = a.name
            domainId    = local.mail_alias_domain_refs[a.domain]
            description = a.description != "" ? a.description : "Mail alias (managed by terraform-minikube-platform)."
            recipients  = { for r in a.recipients : r => true }
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
