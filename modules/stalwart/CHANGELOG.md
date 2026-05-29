# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
