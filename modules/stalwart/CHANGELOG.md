# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
