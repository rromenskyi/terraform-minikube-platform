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

### Stalwart 0.16 email aliases — research the canonical pattern

Adding "alias addresses on a domain" (e.g. `legal@`, `hello@`,
`noc@`, `abuse@` all delivering to a single mailbox, plus optionally
fanning out to external addresses) is unexpectedly painful in the
v0.16 declarative shape. Findings from a ~1h probing session:

- **`MailingList.recipients`** is `Map<PrincipalId, true>`. Stalwart
  expands the recipient set into envelope.to as **principal-ID
  literal strings** (e.g. `"b"`), not the resolved email of the
  underlying Account. The outbound queue then can't route those —
  they have no `@domain`, fall to the smarthost route, the relay
  rejects with `504: need fully-qualified address`. Result: any
  MailingList with internal Account recipients silently bounces
  every incoming message on the alias.
- **`SieveSystemScript`** with `isActive: true` causes the SMTP
  DATA stage to hang indefinitely (RCPT TO accepted, then no
  DATA log entry, no queue id, connection drops). Tested with
  minimal scripts (single internal `redirect :copy`, no `discard`,
  no externals) — same hang. With sieve deactivated, plain mail to
  the same mailbox works. Couldn't isolate root cause; unclear if
  upstream bug, missing wiring, or local config.
- **`Account.aliases`** is documented as embedded `EmailAlias`
  (per stalwart-cli error: "EmailAlias is an embedded property of
  Account or MailingList, not a separate object"). Field shape
  partly reverse-engineered: `aliases/0/name=...` with bare
  local-part probably correct (full email rejected with "Invalid
  email local part"); didn't get to a working full-shape because
  Stalwart admin UI / docs would be the faster path than blind
  probing.
- **MtaRoute smarthost** uses `Address: <IP literal>`; outbound TLS
  verifier fails with cert-name mismatch even though traffic must
  travel a private network path (SNI override field doesn't exist
  on Route). CoreDNS hostname-override workaround already landed
  for one direction (DSN out to gmail via relay), but the smarthost
  is configured by IP literal so DNS override doesn't kick in.
  Either the route spec needs a `serverName` knob or the cert
  needs a SAN covering the IP.

Action when revisiting:
1. Stand up Stalwart admin WebUI (already on `mail.<domain>`)
   and create one alias via UI. Capture the JMAP request the UI
   sends (browser devtools). That gives the canonical EmailAlias
   shape directly.
2. Once shape known, model in engine: per-domain `aliases` map in
   `services.mail` with target Account ID; engine renders
   appropriate `Account.aliases` patches in plan.ndjson.
3. SieveSystemScript hang is a separate bug; defer until needed
   for actual fan-out (external Gmail forwarding etc.).
4. Smarthost cert mismatch: extend MtaRoute `Address` to accept
   hostname (Stalwart resolves it via cluster CoreDNS, picks up
   the hostname-override map), OR enable `allowInvalidCerts: true`
   on a per-route basis since the underlying network path is
   already trust-bounded.

### BuildKit — switch to rootless image + per-binary AppArmor profile

Current shape (`modules/buildkitd`): rootful `moby/buildkit` image,
`securityContext.privileged: true` + `hostUsers: false` (CERN userns
pattern). Privileged inside the container, remapped to an
unprivileged host uid via user-namespace; namespace carries
`pod-security.kubernetes.io/enforce: privileged`. Trust boundary is
the kernel + userns, not PSA admission.

The rootless variant (`moby/buildkit:<ver>-rootless`) was rejected at
adoption time because Ubuntu 23.10+ blocks unprivileged
user-namespace creation by default at the AppArmor `userns_create`
LSM hook (host-side `kernel.apparmor_restrict_unprivileged_userns =
1`). Sidestepping by flipping the host-wide sysctl was the only
mitigation considered — that's a host-wide weakening of the
restriction, so we stayed on the privileged-in-userns pattern.

**The path actually missed:** AppArmor lets you grant
`userns_create` to a **specific binary path** via a profile,
without touching the host sysctl. Profile shape (Ubuntu 24.04+
canonical):

```
abi <abi/4.0>,
include <tunables/global>
profile buildkitd /usr/bin/buildkitd flags=(unconfined) {
  userns,
}
```

Loaded once on every node into `/etc/apparmor.d/` (DaemonSet pattern
— `kube-apparmor-manager`, `security-profiles-operator`, or a
hand-rolled apparmor-loader reading from a ConfigMap). Pod attaches
via `securityContext.appArmorProfile` (GA since k8s 1.31, our
cluster runs 1.34.6):

```yaml
securityContext:
  runAsUser: 1000
  appArmorProfile:
    type: Localhost
    localhostProfile: buildkitd
```

**Why it'd be more secure than the current pattern:**
- Rootless drops every cap; current pattern keeps full caps inside
  userns (mapped to none on host but more in-userns kernel surface).
- `userns_create` permission scoped to ONE binary path vs host-wide
  sysctl flip — minimum-blast-radius approach.
- Native overlayfs in userns (no fuse-overlayfs penalty on Ubuntu
  kernel ≥5.13) — closes the historic perf gap that originally made
  rootful tempting.
- Upstream BuildKit (AkihiroSuda) calls rootless "equivalent to
  running buildkitd as a non-root host user" and treats it as the
  default secure path; CERN's June-2025 post is neutral on choice
  but the upstream trajectory is rootless.

**Per-job ephemeral pods for mixed-trust builds.** Orthogonal to
rootless/rootful: when ARC runners build third-party PR contributions
alongside operator-trusted private repos, switching from the shared
daemon to `docker buildx create --driver kubernetes --bootstrap`
spawns a per-job buildkitd Pod. Cache poisoning between trust levels
disappears (each Pod's cache dies with the job); cost is cold cache
on every build. Pair with rootless. For our home-lab scale this is
overkill today (every build is operator-trusted), but worth
remembering when external-PR CI lands.

**Third options considered + rejected:**
- gVisor RuntimeClass — re-implements syscall surface in userspace;
  breaks `overlayfs` mount → forces `vfs` snapshotter (slow).
- Kata containers — works but heavyweight on a 5-node home lab.

**What changes in the engine:**
1. `modules/buildkitd` swaps image tag to `-rootless` variant + drops
   `privileged: true` + `hostUsers: false` + drops the
   `pod-security.kubernetes.io/enforce: privileged` namespace label.
2. Pod spec gains `runAsUser: 1000` + `runAsGroup: 1000` +
   `securityContext.appArmorProfile.{type=Localhost, localhostProfile=buildkitd}`.
3. New module emits an `apparmor-loader` DaemonSet (or adopts
   `security-profiles-operator`) that lays the profile under
   `/etc/apparmor.d/buildkitd` on every node + `apparmor_parser -r`
   it on container start. ConfigMap carries the profile text so
   updates are git-managed.
4. Operator-side prereq: every node already has AppArmor enabled
   (Ubuntu default — no change on home cluster).

Reference bundle:
- [BuildKit rootless docs](https://github.com/moby/buildkit/blob/master/docs/rootless.md)
- [BuildKit `examples/kubernetes/job.rootless.yaml`](https://github.com/moby/buildkit/blob/master/examples/kubernetes/job.rootless.yaml)
- [Upstream multi-tenant buildkit discussion #5796](https://github.com/moby/buildkit/discussions/5796)
- [Ubuntu 23.10 userns restrictions blog](https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces)
- [Ubuntu 23.10 userns restrictions spec (Discourse)](https://discourse.ubuntu.com/t/spec-unprivileged-user-namespace-restrictions-via-apparmor-in-ubuntu-23-10/37626)
- [Understanding Ubuntu's AppArmor user-namespace restriction (Discourse)](https://discourse.ubuntu.com/t/understanding-apparmor-user-namespace-restriction/58007)
- [Chromium AppArmor userns docs](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md)
- [k8s AppArmor tutorial (`appArmorProfile` field)](https://kubernetes.io/docs/tutorials/security/apparmor/)
- [CERN: Rootless container builds on Kubernetes (June 2025)](https://kubernetes.web.cern.ch/blog/2025/06/19/rootless-container-builds-on-kubernetes/)
- [Sysdig: kube-apparmor-manager pattern](https://www.sysdig.com/blog/manage-apparmor-profiles-in-kubernetes-with-kube-apparmor-manager)

### Migrate MySQL root password to Vault-mode (bootstrap-safe)

`modules/mysql/main.tf` generates `random_password.root` per
Terraform state. On `./tf bootstrap-k3s` (state wipe with
hostPath data preserved at `/data/vol/mysql`) a fresh random
value lands in the `mysql-root` Secret, but InnoDB only applies
`MYSQL_ROOT_PASSWORD` on first datadir init — so the running
MySQL keeps the OLD root password and tenant WP pods start
failing with `Access denied for user 'root'`.

Risk window is narrow (only bootstrap-after-state-loss with
retained data) but real for any tenant whose DB lives on the
shared mysql instance — that data set survives the state wipe
intact, but new credentials don't reach it.

Same pattern as the per-tenant Vault-mode secrets that already
landed (sipmesh-zadarma, sipmesh-twilio, mm-core-secrets, etc.):
operator places root password once in
`secret/data/platform/mysql-root`, engine emits a
`VaultStaticSecret` instead of `random_password +
kubernetes_secret_v1`, VSO syncs into the `mysql-root` Secret in
the platform namespace. State rebuild → no rotation → no drift.

Optionally extend the same pattern to `postgres` / `redis` root
credentials for symmetry — same drift risk shape.

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

### llama.cpp SYCL on Arc B50 — retry on Ubuntu 26.04 + oneAPI 2026.x

Earlier verdict (May 2026, captured in
`project_arc_b50_ollama_sycl` memory): SYCL не вариант on
Battlemage, ipex-llm + upstream llama.cpp SYCL не работали → stay
on Vulkan (17–27 t/s baseline).

The specific blocker that killed that attempt has been fixed:
- **Issue [#21893](https://github.com/ggml-org/llama.cpp/issues/21893)
  (BMG token corruption with `GGML_SYCL_F16=ON
  GGML_SYCL_DEVICE_ARCH=bmg_g21`) is CLOSED** — fixed by
  [PR #21638](https://github.com/ggml-org/llama.cpp/pull/21638),
  merged 2026-04-16; missing `dequantize_block_q8_0_reorder()` added
  so prompt-processing path matches the Q8_0 reorder used during tg.
  No more `GGML_SYCL_DISABLE_OPT=1` workaround needed.
- Q8_0 perf bug [#21517](https://github.com/ggml-org/llama.cpp/issues/21517)
  also being chipped at via the reorder framework — Q8_0 now hits
  ~66% of theoretical bandwidth on the related Arc Pro B70 vs the
  original 21–24%.
- **oneAPI 2026.0** unified Base+HPC toolkit landed with explicit
  BMG-G31 support; recommended SYCL stack now.

**Distro context — Ubuntu 26.04 LTS "Resolute Raccoon"** (released
2026-04-23): ships Linux 7.0 generic kernel (renumbered from the
planned 6.20), `xe` driver default for Xe2/BMG, no `i915` fallback
needed for B50. In-archive `intel-opencl-icd` /
`intel-level-zero-gpu` packages lag — the canonical install path
remains the `intel-graphics` PPA (or the new unified `oneapi` apt
repo) on top of 26.04. Known regression: the **Ollama installer
doesn't recognise 26.04 in its supported-OS list**
([ollama#15827](https://github.com/ollama/ollama/issues/15827),
open) — `libggml-oneapi.so` isn't pulled in even with
`OLLAMA_INTEL_GPU=1`; a workaround would manually link the lib. If
the experiment uses Ollama as the front-end, expect to fight that
detection.

**`chmod 666 /dev/dri/*` workaround** — confirmed render-group GID
mismatch (host `render` GID not mapped into the container). Brute
force; the canonical k8s fix is unchanged: `intel/intel-device-plugins-for-kubernetes`
GPU plugin DaemonSet → request `gpu.intel.com/xe: 1` (or the
`i915` resource name on i915-driven nodes — plugin auto-detects).
The `xe` driver creates the same `/dev/dri/{card,renderD}*` nodes
as `i915`; no new udev rules in 26.04.

**Performance — two contradictory data points** (both real, depend
on quant + driver vintage):
- [Phoronix EOY-2025 + early-2026](https://www.phoronix.com/review/llama-cpp-vulkan-eoy2025):
  Vulkan ~2× SYCL on B580 across the board.
- [Bibek Poudel write-up Apr 2026](https://bibek-poudel.medium.com/how-to-run-qwen3-6-27b-locally-on-intel-arc-pro-b70-what-actually-works-c96dec67c6f7)
  (B70 on Ubuntu 25.10 + oneAPI 2025.3): SYCL 22 t/s vs Vulkan
  14–15 t/s on Qwen3.5-27B (+52%).

So with post-#21638 llama.cpp + oneAPI 2026.x, SYCL is **plausibly
faster** than the current 17–27 t/s Vulkan baseline on B50,
especially for Q4_K_M / Q8_0. Not guaranteed — depends on model.

**Third options:**
- **`ipex-llm`** — archived read-only Jan 2026. Dead. Don't touch.
- **vLLM XPU** — actively maintained but has its own BMG bugs
  ([vllm#41663](https://github.com/vllm-project/vllm/issues/41663)
  — XPU TP=2 GP-fault on dual B70 with Ubuntu 24.04 HWE 6.17). For
  single-GPU it's fine.
- No Intel-published "official k8s pattern" beyond the device
  plugin + standard SYCL container images.

**Bottom line:** one retry of llama.cpp SYCL on 26.04 + oneAPI
2026.x + llama.cpp ≥ b5500 is worth it. Vulkan stays the
lower-friction fallback in the same perf envelope, so a backout is
cheap. Update / supersede `project_arc_b50_ollama_sycl` memory
either way after the experiment.

Reference bundle:
- [llama.cpp SYCL backend docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/SYCL.md)
- [llama.cpp Discussion #12570 — Arc status](https://github.com/ggml-org/llama.cpp/discussions/12570)
- [Intel dgpu-docs client install](https://dgpu-docs.intel.com/driver/client/overview.html)
- [Intel GPU device plugin for k8s](https://github.com/intel/intel-device-plugins-for-kubernetes/blob/main/cmd/gpu_plugin/README.md)
- [Ubuntu 26.04 LTS release notes](https://documentation.ubuntu.com/release-notes/26.04/)
- [Ubuntu 26.04 / Linux 7.0 (ServeTheHome)](https://www.servethehome.com/ubuntu-26-04-lts-moving-the-industry-forward-with-linux-7-0-and-more/)
- [ipex-llm repo (archived)](https://github.com/intel/ipex-llm)

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
