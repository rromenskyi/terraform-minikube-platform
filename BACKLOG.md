# Backlog

Open work, in rough priority order. Sized for a single operator —
each item is a sit-down session, not a sprint.

## Hot — needed for mail to be production-correct

### Reconsider Stalwart vs a traditional Postfix + Dovecot + Roundcube pod

Stalwart was picked for "all-in-one Rust + native OIDC + declarative
JMAP config". Reality has been bumpier: Stalwart's bundled WebUI does
not include a mailbox view, so a separate webmail (Roundcube) is
bolted on top anyway; the OIDC integration cost roughly three days
of debugging (Zitadel JWT access tokens carry no `scope` claim, so
Stalwart's hardcoded `openid` scope check fails until `requireScopes`
is explicitly empty; Stalwart caches `OidcDirectory` at startup, so a
schema change applied by the applier sidecar after Stalwart is up
needs a second pod rollout to take effect; the JMAP `apply` engine
groups all destroys before all updates, which silently breaks any
plan that relies on a pre-destroy detach).

The traditional Postfix + Dovecot + Roundcube stack — plain SASL auth,
no SSO — is older but solves the same operational goal in a fraction
of the time, fits in a few hundred lines of yaml, and has decades of
operational muscle memory behind it.

When Stalwart's next rough edge surfaces, evaluate ripping it out:
drop `mail.tf`, `modules/stalwart`, `modules/roundcube`, the Zitadel
app + project for Stalwart, and the `mail.yaml` external component;
replace with a `kind: deployment` component wrapping Postfix +
Dovecot + Roundcube, or a maintained `mailcow` / `docker-mailserver`
helm chart. The trade-off lost is OIDC SSO into Stalwart's admin
panel (which only the operator ever sees) — small in exchange for
reliability.

Alternative: wait for Stalwart upstream to release a mailbox UI in
their `webui` bundle (on their public roadmap as of writing) and
revisit then.

### Make Cloudflare Tunnel optional for public-IP deploys

Today the platform is hard-wired to Cloudflare Tunnel: every tenant
hostname is a CNAME to `<tunnel-id>.cfargotunnel.com`, cloudflared
runs as a Deployment in `ops`, and `cloudflare.tf` is unconditionally
loaded. This is the right shape for a residential ISP behind a NAT
and ISP-blocked :25 / :80 / :443 — that's where this cluster runs
today. It's the wrong shape for a public-IP VPS deploy: there the
provider already gives you working :80 / :443 / :25, cloudflared is
extra latency and an extra moving part, and the simpler Traefik +
cert-manager LetsEncrypt direct path works fine.

Plan: gate the whole CF Tunnel chain behind a `var.public_ingress`
flag (default `cloudflare_tunnel` for backwards-compatibility on the
home box; `direct` for VPS deployments). When `direct`:

- Skip `cloudflare_zero_trust_tunnel_cloudflared.main` and the
  cloudflared Deployment.
- DNS records become A/AAAA at the VPS public IP rather than CNAME
  at `*.cfargotunnel.com`.
- `cert-manager` switches from cluster-internal HTTP-01 (which
  currently tunnels through cloudflared, fragile) to either HTTP-01
  on the publicly reachable :80 or DNS-01 via the Cloudflare API
  (which we already have a token for).
- Traefik exposes :80 and :443 via a hostNetwork or NodePort
  Service rather than only `ClusterIP` reachable through cloudflared.
- The `force-https-proto` middleware that currently rewrites
  `X-Forwarded-Proto` for cloudflared origin requests becomes a no-op
  (Traefik terminates TLS itself).

Trade-off: on `direct` you lose Cloudflare's DDoS shield + WAF +
per-zone rate limits. Acceptable for a small VPS where the threat
model is "drive-by scans, not nation-state".

Order of operations when this lands: a fresh `direct` deployment
should bring up the cluster, route mail.example.com / id.example.com
/ chat.example.com / etc. on the VPS public IP, validate certs from
LetsEncrypt over the standard public path, and never fetch a single
byte through cloudflared. Existing `cloudflare_tunnel` deploys
should require zero change.

### Platform secrets store — superseded: Vault community after Infisical paywall

(Originally tracked as "Infisical as the platform secrets store
(Zitadel-OIDC-gated)". Closed after a real apply on the home cluster
exposed two blockers in the v0.74-postgres self-host build: `oidcSSO`
is set to `false` in `getDefaultOnPremFeatures()` so the SSO settings
UI is grayed out for non-Pro tenants, and POST `/api/v1/sso/oidc/config`
denies machine-identity actors with CASL 403 even when the bearer is
a fully-authorised Universal-Auth `tf-platform` Admin identity. Two
PRs landed and were reverted: #30 stood up the empty Phase 0 module
and #31 attempted Phase 1 OIDC and was closed without merge.)

Replacement target: **HashiCorp Vault community edition**. Free OIDC
auth method, mature `hashicorp/vault` TF provider with native CRDs
for mounts/policies/KV/identity, k8s-side consumer story via Vault
Agent Injector or Vault Secrets Operator. Trade-off versus Infisical:
worse UI polish but no paywall on SSO, and the unseal ceremony is
solved by an init container that reads unseal keys from a
`kubernetes_secret_v1` populated by a one-time `vault operator init`
Job (same shape as the Stalwart applier sidecar / Zitadel pat-broker).

Roadmap stays four-phase, mirroring the Infisical attempt:

1. **Phase 0** — module skeleton, raft storage, hostPath PV, init
   Job + auto-unseal init container, root token output for break-
   glass. Public route `vault.<domain>` (or reuse `secrets.<domain>`
   if migrating in place).
2. **Phase 1** — Zitadel JWT auth method via
   `vault_jwt_auth_backend` + role mapping Zitadel `vault_admin` /
   `vault_operator` claims to Vault policies. UI login page gets the
   "Sign in with OIDC" button automatically.
3. **Phase 2** — first migrated secret (lowest blast radius:
   per-project Traefik dashboard BasicAuth password). Vault Secrets
   Operator + a `VaultStaticSecret` CR materialise `kubernetes_secret_v1`
   in the consumer namespace. Existing `env_from`-style consumption
   stays unchanged.
4. **Phase 3** — bulk migration of cheatsheet-bound TF outputs
   (mysql.root, postgres.superuser, redis.default, zitadel.admin,
   the rest of basic_auth). Per-tenant DB credentials keep their
   `kubernetes_secret_v1` lifecycle.
5. **Phase 4** — drop the secret-bearing rows from
   `outputs.tf::cheatsheet` once dual-write has soaked.

Open question deferred to Phase 0 design: keep the "platform-services
share one Postgres" pattern by using Vault's external Postgres backend,
or ship raft (Vault's bundled key-value store) for simplicity. Lean
towards raft because it removes a cross-service dep and matches
Stalwart's RocksDB-internal-store choice.

### Multi-domain support for the mail stack

Today the mail stack is single-domain: exactly one entry under
`config/domains/<x>.yaml#mail.primary: true` drives `local.mail`,
and `modules/stalwart` emits SPF/DKIM/DMARC for that one domain
only. Stalwart itself happily hosts mailboxes for many domains; the
gap is on the TF side (DNS records + Zitadel role + DKIM key
generation).

Plan: shift `local.mail` from a single-domain object to a map keyed
by domain, with `mail.enabled: true` (no `primary` flag — the
single-domain case is just a one-entry map). `modules/stalwart`'s
DKIM/SPF/DMARC `cloudflare_record` resources gain a `for_each` over
that map; one DKIM key per domain (`tls_private_key.dkim` becomes
keyed). The relay (smarthost) typically stays one-and-the-same;
extend its `relay_domains` (Postfix) to accept all configured
domains.

## Medium — quality of life

### Consolidate Zitadel projects: per-domain, not per-app

Today every Zitadel-integrated app — `kind: app` components plus
cluster-wide infra clients (forward-auth, future Grafana SSO,
Traefik SSO) — gets its own Zitadel project. With N apps, the
operator stares at N nearly-empty projects in the Zitadel console.

Proper layout: **one project per tenant domain** holding all that
domain's kind:app components, plus **one `platform-services`
project** for cluster-wide infra OIDC clients. ~5 projects total
forever, vs growing 1-per-app indefinitely.

Refactor: hoist project creation out of `modules/zitadel-app` and
`modules/oauth2-proxy` into the layer that owns the scope —
`modules/project` for tenant domains, root TF for platform — and
pass `project_id` down to the per-app module. Roles still belong to
the per-app module (they're application-scoped within the project).

### Auto-recovery for `login-client.pat` after pod restart

Today the operator has to extract the FIRSTINSTANCE-generated PAT
once and paste it into `.env` as `TF_VAR_zitadel_login_client_pat`,
otherwise the next pod restart hangs forever at "waiting for
login-client.pat...". Mild chicken-and-egg — fresh installs are
fine, restarts after first install are operator-blocking.

Proper fix: extend the `pat-broker` sidecar in
`modules/zitadel/main.tf` to ALSO save `login-client.pat` (alongside
the tf-platform PAT) to a Secret on first observation, and add an
initContainer that, when the Secret exists but the emptyDir is
empty, copies `login-client.pat` from Secret back to the emptyDir
before the main containers start. After this lands:

1. Drop `var.login_client_pat` from `modules/zitadel/main.tf`.
2. Drop `TF_VAR_zitadel_login_client_pat` from `.env`.
3. Drop the operator-bootstrap step from the variable's docstring.

### Diagnostic recipes — how to look at cluster state

Worth pulling out into `docs/diagnostics.md` as a quick-reference for
the operator (and for future-me staring at a stuck cluster). The
recipes that came up while building the mail stack:

**Where's free CPU/memory on the node?**
```bash
kubectl describe node | grep -E '^Name:|Allocatable:|Allocated|cpu '
kubectl top node
```
First gives the static Allocatable + the requests/limits tally that
the scheduler actually uses (the "77% of limits at 1.8 CPU
requests" view). Second gives live usage from metrics-server. Bump
namespace quotas only after checking the requests/limits column —
that's the gate, not real CPU.

**Why is a pod Pending / FailedCreate?**
```bash
kubectl describe rs -n <ns> <rs-name> | grep -A6 Events:
```
Catches ResourceQuota denials with the exact `requested:` vs
`used:` vs `limited:` numbers, plus PVC binding waits, image-pull
backoffs.

**What's actually on host port X?**
```bash
sudo ss -lntp 2>&1 | grep ':<port>'
```
Catches stale `kubectl port-forward` holdovers, or whether a
hostNetwork pod actually grabbed the port. `pgrep -af 'port-forward'`
correlates back to which `./tf` invocation owns the listener.

**Is Traefik forwarding what I think it is?**
```bash
kubectl get deploy -n ingress-controller traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args[*]}' | tr ' ' '\n'
```
Dumps the runtime CLI args after the helm chart settles — the only
truth about which entryPoints are configured and what
forwardedHeaders trust looks like in production.

**What's the actual response chain through CF Tunnel?**
```bash
curl -sIv 'https://<host>/' 2>&1 | grep -iE '< http|< location'
```
Quick way to see if Traefik is returning 307/302 (auth flow firing)
or 500 (Traefik failing to proxy auth response). Cheaper than
F12-Network-tab walkthrough for the operator.

**Why is a TF-managed pod running with a stale spec?**
- TF state may have lost the Deployment (e.g. after a `state rm`).
  `terraform state list | grep <name>` catches that case.
- The cluster has a zombie Deployment — `kubectl delete deploy/<name>`
  + `terraform apply` recreates it cleanly.

### Stalwart admin still uses internal user/password

`modules/oauth2-proxy` puts the cluster-wide forward-auth gate in
front of the admin UI for the network-level gate, but Stalwart
itself doesn't speak OIDC for its admin login. Two-factor in
practice (Zitadel forward-auth + Stalwart's own admin password).
Sufficient for v1. If it annoys: bridge Zitadel to Stalwart's
userdb via SCIM, or enable Stalwart's IMAP+OIDC if a future version
supports admin OIDC.

### platform-dash CRD viewer

`kubectl get` for IngressRoute + Middleware + IngressRouteTCP +
ServersTransport is verbose enough that hand-pasting YAML into
`yq` is the actual debugging workflow. Add a generic CRD lister
to `platform-dash` (uses `KubernetesObjectApi` from
`@kubernetes/client-node`, RBAC already covers `traefik.io/*`).

## Cosmetic — fix opportunistically

### `./tf` wrapper port-forward wait timeout

Wrapper prints `tf: port-forward never became ready, continuing
anyway` on most invocations because `kubectl port-forward` takes
longer than its sleep-based wait. Apply works (port-forward IS up
by the time the Zitadel provider hits it), but the message is
alarming-looking for no reason. Bump the wait or switch to a TCP
probe loop.

### `tf-summarize` on the operator box

Plan output from this stack is dense (especially when CF tunnel
ingress_rule indices shift). Install `tf-summarize` (Go binary) and
pipe `./tf plan -out=tfplan && terraform show -json tfplan |
tf-summarize` for a human-readable summary.

### Cloudflare provider v5 upgrade for keyed ingress_rules

v4's `cloudflare_zero_trust_tunnel_cloudflared_config` stores
`ingress_rule` blocks as a positional list — adding a hostname
shifts every subsequent index, and TF shows full block diffs for
each shift. v5 might use a keyed map. Big upgrade (other resources
rename: `cloudflare_record` → `cloudflare_dns_record`, etc.) so
not worth a session of its own; bundle with the next reason to
touch the provider.
