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

### Infisical as the platform secrets store (Zitadel-OIDC-gated)

All sensitive material currently lives in two places: `terraform output
-raw <name>` for things that originate in TF (recovery admin password,
DB superuser passwords, smart-host credentials, basic auth pairs) and
`kubectl get secret … -o jsonpath` for per-namespace per-component
credentials. Both rotate on `./tf bootstrap-k3s` but otherwise sit in
state and on disk indefinitely. Every operator look-up (cheatsheet,
"give me the redis password") is a CLI ritual.

Plan: deploy Infisical as a platform service in the `platform`
namespace, OIDC-gated through Zitadel (a `mail-user`-style project
role on a new Infisical Zitadel app gates access), and migrate every
TF-managed secret into it. Components that need a credential read it
out of Infisical at runtime via the in-cluster API rather than out of
a hand-rolled `kubernetes_secret_v1`. Operator look-up shifts from
`terraform output -raw` to a single Infisical UI/CLI gated by the
same SSO that fronts the cluster.

Open questions:

1. **TF integration shape** — `infisical/infisical` provider exists
   for declarative project + folder + secret-key creation, but the
   write path conflicts with the bootstrap chicken-and-egg (the
   provider needs Infisical reachable to plan; first apply has to
   bring Infisical up before any other component can resolve its
   secrets). Either: phased apply (Infisical comes up empty, then a
   second pass populates secrets and rewires consumers) or write all
   secrets via a `null_resource + local-exec` after Infisical is
   ready and pre-mark them in TF state as imports.

2. **Consumer pattern** — components currently read TF-managed
   `kubernetes_secret_v1` via env-var. Two integration options:
   `infisical-agent` sidecar that watches Infisical and rewrites a
   local Secret on change, or the operator-flavour Infisical
   ServiceAccount + CSI driver (CSI = colder, more native, more
   moving parts). Lean towards sidecar for the small number of
   components on this cluster.

3. **Bootstrap admin** — Infisical itself needs an initial admin
   account before OIDC is wired in. Mirror the Stalwart pattern:
   `INFISICAL_RECOVERY_ADMIN` env-pinned plus a `random_password`
   resource and a `terraform output -raw infisical_recovery_admin_password`.

4. **What gets migrated first** — start with the things the
   operator actually looks up from the cheatsheet (mail recovery
   admin, BasicAuth pairs, MySQL/Postgres/Redis root passwords).
   Per-tenant DB credentials probably stay as-is for now since they
   get composed into per-component env-vars at TF-render time.

When this lands, drop the secret-bearing rows from
`outputs.tf::cheatsheet` and replace with a single line pointing at
the Infisical URL.

### ~~PTR for `relay.ipsupport.us`~~ — done 2026-04-30

VPS provider rDNS now resolves `130.51.23.250` → `relay.ipsupport.us`.
No further action; leaves SPF/DKIM/DMARC alignment as the remaining
deliverability gate.

### Stalwart wizard + DNS records (DKIM / SPF / DMARC)

Mail server is up but unconfigured. Walk the wizard at
`https://mail.ipsupport.us`:

1. Set the admin password.
2. Add domain `ipsupport.us`.
3. Generate DKIM key (Domains → ipsupport.us → DKIM → Create).
4. Optionally create accounts (`roman@ipsupport.us`, etc.).

Then add the mail-related DNS records to the `dns:` block in
`config/domains/ipsupport.us.yaml` (the static A/AAAA records are
already there; this is just the TXT/MX additions):

- MX `ipsupport.us` → `relay.ipsupport.us` (currently set by hand
  on Cloudflare — move into the YAML and import into state, OR let
  TF recreate it).
- SPF TXT on `ipsupport.us`: `v=spf1 ip4:130.51.23.250 -all`.
- DKIM TXT (key emitted by Stalwart): `<selector>._domainkey...`.
- DMARC TXT on `_dmarc.ipsupport.us`:
  `v=DMARC1; p=quarantine; rua=mailto:postmaster@ipsupport.us`.

The DNS-as-YAML schema supports MX (`type: MX, content: "10 relay.ipsupport.us"`)
and TXT (`type: TXT, content: "v=spf1 ..."`) directly via the flat
`content:` form; SRV/CAA/LOC use the structured `data:` form.

### Outbound mail relay covers more than `ipsupport.us`

`gh/ansible-relay.ipsupport.us` Postfix `relay_domains` list is
currently single-domain. When other tenant domains
(`jagdterrier.club`, `paseka.co`, `priroda.kharkov.ua`) need mail,
add them to `relay_mail_domains` in
`inventories/prod/group_vars/mail_relay_vps.yml` and re-apply.
Document this in the repo's README so it's a one-grep ops note.

## Medium — quality of life

### Consolidate Zitadel projects: per-domain, not per-app

Today every Zitadel-integrated app — `kind: app` components
(platform-dash, sipmesh-frontend) plus cluster-wide infra clients
(forward-auth, future Grafana SSO, Traefik SSO) — gets its own
Zitadel project. With N apps, the operator stares at N nearly-empty
projects in the Zitadel console.

Proper layout: **one project per tenant domain** (`ipsupport.us`,
`jagdterrier.club`, `paseka.co`, `priroda.kharkov.ua`) holding all
that domain's kind:app components, plus **one `platform-services`
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
recipes that came up in this session:

**Where's free CPU/memory on the node?**
```bash
kubectl describe node | grep -E '^Name:|Allocatable:|Allocated|cpu '
kubectl top node
```
First gives the static Allocatable + the requests/limits tally that
the scheduler actually uses (your "77% of limits at 1.8 CPU
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



### Ansible-relay → Ansible-mail rename

The repo `gh/ansible-relay.ipsupport.us` covers the VPS relay
**and** will soon cover the home backend's WireGuard config (which
is currently a manual `wg-quick@wg0` install). Rename to
`ansible-mail`, add a `mail_home_backend` group + `wireguard_client`
role for the home host so the WG bring-up is reproducible. Inventory
gains a second host.

### LAN-side firewall for the SMTP forwarder pod

`stalwart-smtp-relay` is `hostNetwork=true` and binds explicitly to
`10.23.0.2:25` (WG IP), so it's NOT exposed on the LAN. But the
choice was a property of the bind address. Belt-and-suspenders: add
a host-level ufw rule (managed via `ansible-mail`) that explicitly
denies `:25` from the LAN interfaces, only allowing from the WG peer.

### Stalwart admin still uses internal user/password

We layered Zitadel forward-auth in front of the admin UI for the
network-level gate, but Stalwart itself doesn't speak OIDC for its
admin login. Two-factor in practice. Sufficient for v1. If it
annoys: bridge Zitadel to Stalwart's userdb via SCIM, or enable
Stalwart's IMAP+OIDC if a future version supports admin OIDC.

### platform-dash CRD viewer

`kubectl get` for IngressRoute + Middleware + IngressRouteTCP +
ServersTransport is verbose enough that hand-pasting YAML into
`yq` is the actual debugging workflow. Add a generic CRD lister
to `platform-dash` (uses `KubernetesObjectApi` from
`@kubernetes/client-node`, RBAC already covers `traefik.io/*`).
Detailed scope in `~/.claude/projects/-home-roman220/memory/project_platform_dash_backlog.md`.

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

### CRD viewer is the load-bearing dash item

(See platform-dash backlog above.) Other dash work (sparkline
metrics, real Nodes/Monitoring pages, light theme) is deferred —
Grafana covers metrics and the operator hasn't asked for the
others yet.
