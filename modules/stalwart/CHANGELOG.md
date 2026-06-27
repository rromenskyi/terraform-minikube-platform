# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- **`internal_trusted_ip_patterns` — skip the spam filter for trusted
  in-cluster senders.** New list variable (default `[]`, a no-op). When
  set, the DATA-stage `enableSpamFilter` expression keeps Stalwart's
  stock default (`is_empty(authenticated_as)`) and ANDs in a
  `!matches(<regex>, remote_ip)` exclusion per pattern. Internal mail
  delivered straight to `:25` (e.g. Alertmanager → mail) comes from a
  pod IP, fails public SPF/DMARC, and was being spam-scored to Junk;
  trusting the cluster IP range lets it land in the inbox. Regex (not
  CIDR) because Stalwart 0.16.x has no CIDR expression function. Emitted
  as a separate `MtaStageData` PATCH so it coexists with the
  ingest-forward `script` binding.
- **`wait-zitadel` init container — survive node reboots without a
  manual restart.** When OIDC is enabled, an init container now blocks
  the main Stalwart container until the configured `zitadel_issuer_url`
  discovery endpoint (`/.well-known/openid-configuration`) is reachable.
  On a node reboot Stalwart otherwise comes up before Zitadel
  (`id.<domain>`) is back, fails to fetch OIDC keys, then rejects every
  token and serves no TLS until someone restarts it. The wait is bounded
  (~5m, 100 × 3s) and then starts anyway, so a genuinely-down Zitadel
  never blocks SMTP mail delivery — it only falls back to the prior
  start-anyway behaviour. Gated on `local.oidc_enabled` (no-op when OIDC
  is off).
- **`ingest_forwards` entries take a LIST of `addresses`.** One forward
  now fans several tagged mailbox addresses into the SAME listener via a
  single Sieve `anyof(envelope :is "to" ...)` rule — e.g. `mail@` (bounce
  VERP `mail+<token>@`) + `reply@` (reply-conversion `reply+<id>@`) both
  push to the campaign-ingest listener; the consumer branches on the
  tagged local-part it reads from `X-Original-To`. Each address must
  resolve to a deliverable mailbox/alias (the `:copy` keeps the original
  locally). Replaces the former single `address` field.
- **VERP attribution on ingest forwards — `X-Original-To` header.** Each
  forward's Sieve rule now stamps `X-Original-To` on the forked copy,
  recovered from the relay's `Received: ... for <addr>` clause. Stalwart
  strips subaddressing (`mail+<token>@`) *before* the DATA-stage Sieve
  runs — `:detail`/`:all` return the bare address, so the VERP token is
  not recoverable from the envelope (verified). The relay (Postfix)
  records the true envelope recipient in its `Received` `for` clause
  *before* Stalwart, so the script extracts it there into
  `X-Original-To` for the consumer (works even when `To:` is the
  original sender, as in real DSNs). No-ops cleanly when no `for` clause
  exists. Adds the `editheader` + `variables` Sieve requires.
- **`ingest_forwards` — SMTP-push machine intake for mailbox traffic.**
  Map of slug → { address, synthetic_domain, smtp_host, smtp_port }.
  Each entry adds a `redirect :copy` rule (every message whose SMTP
  envelope recipient is `address` → `ingest@<synthetic_domain>`) into
  ONE combined DATA-stage Sieve script (`ingest-forwards`), plus its
  own MtaRoute Relay pinning the synthetic domain to a plain-SMTP
  in-cluster listener. The script is bound via `MtaStageData.script`
  (an Expression object — `{match, else}`, the `else` names the
  script) and **coexists with the spam filter** (left enabled; both
  run at the DATA stage — verified e2e). The Sieve matches the SMTP
  envelope recipient (`envelope :is "to"`), not the `To:` header, so
  bounces/DSNs (whose header carries the original sender) are caught.
  Built for campaign bounce/DSN ingest by a backend service: realtime
  push at delivery, zero mailbox credentials (the auth directory is
  external/OIDC — internal account passwords aren't even possible),
  original kept in the mailbox, SMTP queue+retry when the listener is
  down. **Critical applier change:** the running server caches
  `MtaStageData` at startup, so the applier now triggers a
  `ReloadSettings` action after the apply when forwards exist — without
  it the DATA-stage binding stays inert (same start-time-cache class
  the OIDC Directory idempotency works around; cost us a full debug
  cycle). The applier's stale-object pre-step is generalised from the
  single `smarthost` route to every `ingest-*` MtaRoute + the
  `ingest-forwards` script. The single combined `MtaOutboundStrategy`
  update now composes the per-domain ingest branches ahead of the
  smarthost/mx fallback (and is emitted even with no smart host).

### Fixed
- **Applier no longer fails 3 ops on every Stalwart start (clean convergence).**
  The Domain idempotency now covers *every* domain in the plan (primary +
  each `additional_domains` entry), not just the primary — re-applies no
  longer `primaryKeyViolation` on `dom-add-<slug>`. Added DkimSignature
  idempotency: Stalwart auto-generates a DKIM signature per Domain (rotation
  selectors `v1-rsa-<date>`), so the explicit `create DkimSignature` failed
  (`invalidPatch` / duplicate) on any domain that already had one; the applier
  now drops any DkimSignature create whose target Domain already has a
  signature, keeping creates only for brand-new domains. Apply now reports
  `0 failed` instead of 3.
- **OIDC login no longer breaks after a Stalwart pod restart / node reboot.**
  The applier used to `destroy` + recreate the OIDC `Directory` on every run,
  minting a new internal id and re-pointing `Authentication` at it; the running
  server had cached the *old* id at startup, so after the applier's mutation
  every OIDC login resolved a dangling directory until a manual restart. The
  plan no longer destroys the Directory, and the applier now rewrites the plan
  to skip `create Directory dir-zitadel` + resolve `#dir-zitadel` to the
  existing id when one is present (the same idempotency already used for
  `Domain`). The Directory id is now stable across applies, so the start-time
  cache stays valid and the `Authentication.directoryId=null` detach pre-step
  (only needed because of the destroy) is removed.

### Added
- **`additional_domains` variable for multi-domain submission-only mail.** Map of
  slug → { name, dkim_selector?, dmarc_policy? }. Engine generates one
  RSA-2048 DKIM keypair per entry and adds a Stalwart `Domain` +
  `DkimSignature` pair to the apply plan. Outgoing mail with `From:`
  matching an additional domain is signed with that domain's key. No
  accounts / mailboxes auto-created — additional domains are
  submission-only (outbound), no inbound mailboxes or per-domain user
  provisioning. New output `additional_domain_dkim_dns` (map slug → {
  name, value }) consumed by root `mail.tf` to publish DKIM TXT records
  on each additional zone. SPF / DMARC / MX records for additional
  domains are also emitted from root using the same iteration.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
- Pod spec now sets `service_account_name = "default"` explicitly on the
  Deployment. The kubernetes Terraform provider doesn't reliably clear a
  previously-set string field by omission, so leaving the field implicit
  leaves the live Deployment pinned to whatever SA was last assigned. With
  the explicit value, a future Pod-side SA change (or removal) actually
  propagates through `terraform apply`. Defensive only — current Deployment
  was already pointing at `default`; this just makes the intent
  declarative.
