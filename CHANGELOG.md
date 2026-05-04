# terraform-minikube-platform Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **BREAKING** `modules/project` input renamed `argocd_bootstrap` (single object) → `argocd_bootstraps` (map of objects keyed by short name). Engine emits one root Application per entry as `<namespace>-<key>-bootstrap`; AppProject `sourceRepos` aggregates every entry's `repo_url` so sub-Applications cross-referencing peer repos pass the allowlist. Domain-yaml input renamed under `envs.<env>.argocd_bootstrap:` → `envs.<env>.argocd_bootstraps:`. **Migration:** wrap the old singular block as a map under any key — the key becomes the Application-name suffix, so the first apply destroys the legacy `<ns>-bootstrap` and re-creates `<ns>-<key>-bootstrap`. Apply requires operator OK because the bootstrap Application is destroy-replaced; sub-Applications themselves keep their own names and re-attach automatically once the new bootstrap App syncs.
  ```yaml
  # before
  argocd_bootstrap:
    repo_url: git@github.com:org/deploy.git
    path: deploy/argocd/apps
    target_revision: main
    repo_ssh_key_id: deploy

  # after
  argocd_bootstraps:
    deploy:                                # any key — becomes the Application name suffix
      repo_url: git@github.com:org/deploy.git
      path: deploy/argocd/apps
      target_revision: main
      repo_ssh_key_id: deploy
  ```

### Added
- Multiple `argocd_bootstraps:` entries per project/env are now supported — primary use case is a single project namespace served by independent chart repos (e.g. a backend chart at `git@github.com:org/backend.git` and a frontend chart at `git@github.com:org/frontend.git`, both deploying into the same `phost-…` namespace with their own `deploy/argocd/apps/application-<env>.yaml`). One AppProject still scopes the entire namespace; its `sourceRepos` list is the union of every entry's `repo_url`.

### Fixed
- `modules/redis` and `modules/project` switch Redis from `--requirepass` to `--aclfile /data/users.acl` so per-tenant ACL users survive `redis-0` restarts. Pre-fix every tenant lost its Redis login on the next pod bounce because `ACL SETUSER` only persisted in memory; now the tenant setup Job runs `ACL SAVE` after each `SETUSER`, and a `seed-users-acl` initContainer in the Redis StatefulSet writes the `default` user line on first boot from `$REDIS_PASSWORD` so the platform-root password keeps working too. `requirepass` and `aclfile` are mutually exclusive in Redis (server refuses to start with both); the migration is invisible from a fresh-volume bootstrap and self-heals on first restart for existing volumes (initContainer sees missing/empty `users.acl` and seeds it; tenant Jobs re-apply `SETUSER` + `SAVE`)

### Changed
- `config/components/chat.yaml` pins Open WebUI to `ghcr.io/open-webui/open-webui:v0.9.2` (was the moving `:main`) for reproducible tenant deploys, aligned with the upstream `0.9.2` release published 2026-04-24
- `config/components/chat.yaml` `MODEL_FILTER_LIST` swapped from the old `qwen2.5:7b/14b/coder + gemma4` lineup to the new `qwen3.5:0.8b,qwen3.5:2b,qwen3.5:4b,qwen3.5:9b,qwen3:14b,gemma4:e2b,gemma4:e4b` set. Tiny `qwen3.5:0.8b` (~600 MB) and `qwen3.5:2b` (~1.4 GB) ride along for snappy single-shot prompts where the bigger sibling round-trip latency feels heavy. `DEFAULT_MODELS` stays on `qwen3.5:9b`. Operators on the old `qwen2.5` family must re-pull on the shared Ollama (`config/platform.yaml` `services.ollama.models`); README sample updated to match.
- `config/components/chat.yaml` pins `mcp-weather` sidecar to `ghcr.io/rromenskyi/mcp-weather-simple:v1.1.0` (was `:latest`). v1.1.0 is the first upstream release where `MCP_ROUTER_MODE` defaults to `fat_tools_lean` (~79% smaller catalog, same hit rate); we don't override the env so the upstream default is what runs. Reproducible deploys + AGENT.md compliance ("no moving tags").

### Added
- `modules/component` learns a `sidecars:` map — additional containers that run in the same Pod as the component's main container. Keyed by container name; each entry takes `image`, optional `command` / `args` (ENTRYPOINT / CMD override), `env_static`, `env_random` (list of keys pulled from the shared component-level random-env Secret via `valueFrom.secretKeyRef`), `writable_paths` (per-sidecar emptyDir volumes for every listed mount path, defaulting to `["/tmp"]`), `resources`, and an optional `security` block (defaults: `run_as_user: 1000`, `read_only_root_filesystem: true`; `run_as_user: 0` is supported for images whose entrypoint needs root and flips `run_as_non_root` automatically). No Service port, no probes — sidecars are invisible outside the Pod and the main container's probes cover Pod liveness. Intended for helper servers the main container reaches over loopback (MCP tool servers, terminals, local caches, token refreshers)
- `config/components/chat.yaml` now ships `mcp-weather-simple` (https://github.com/rromenskyi/mcp-weather-simple) as a sidecar of Open WebUI on `127.0.0.1:8000` and pre-registers it via `TOOL_SERVER_CONNECTIONS` so the chat model can call `get_current_weather`, `get_forecast`, and `geocode_city` out of the box. The sidecar runs with `MCP_AUTH_TOKEN` intentionally unset — loopback inside a single Pod is the trust boundary, so the bearer-token middleware is skipped
- `config/components/chat.yaml` now also ships `open-terminal` (https://github.com/open-webui/open-terminal, `:alpine` variant, ~230 MB) as a second sidecar on `127.0.0.1:8001`, pre-registered via `TERMINAL_SERVER_CONNECTIONS` so the chat model can execute shell commands, manage files and run code through Open WebUI's dedicated Terminal integration. The image's hardened entrypoint (iptables egress firewall + `su-exec` privilege drop) is bypassed via a `command:` override since the Kubernetes NetworkPolicy layer already enforces egress; that lets the sidecar run cleanly as UID 1000 under the Pod's restricted securityContext. The bearer token is shared with Open WebUI's backend through one `env_random: [OPEN_TERMINAL_API_KEY]` entry and reaches `TERMINAL_SERVER_CONNECTIONS` via Kubernetes `$(VAR_NAME)` substitution. Session state lands on an emptyDir at `/home/user` — scratch-only, lost on Pod restart, which is the right lifetime for a chat-session terminal
- **Both integrations still need one manual "Verify + Save" click** per tenant in Admin → Settings → External Tools / Integrations on the first fresh data volume until upstream fixes open-webui/open-webui#18140; a `kubernetes_job_v1` that calls the admin API is a straightforward follow-up if the click starts to bite
- `modules/component` new input `image_pull_policy` — one of `Always`, `IfNotPresent`, `Never`, or unset to auto-derive from the image reference (the default). Auto-derivation mirrors Kubernetes' own native behavior: a moving tag (`:latest` or an empty/implicit tag) resolves to `Always`, a pinned tag (`:1.2.3`, `:main`, …) or digest pin (`@sha256:...`) resolves to `IfNotPresent`. `modules/project` forwards `try(each.value.image_pull_policy, null)` so a component YAML can set an explicit override under either the top-level `image_pull_policy:` field (main container) or `sidecars.<name>.image_pull_policy` (per sidecar). Unblocks rollouts of moving-tag images (`:latest` stopped refreshing after the first pull under the previous `IfNotPresent` default coming from the kubelet) without forcing every pinned workload to pay the per-Pod-start HEAD

### Changed
- `modules/component` now emits `env_random` values as explicit `env` entries with `valueFrom.secretKeyRef` instead of a single `env_from` block. Functionally equivalent for components that only read these vars — but it enables Kubernetes `$(VAR_NAME)` substitution in subsequent `env_static` values, which `envFrom`-sourced vars don't participate in. Consumers that want to reference a random-env key inside a static-env value (e.g. embedding a bearer token in a JSON connection blob) can now do so without Terraform-side glue. The `env_random_keys` input on `modules/component` is populated automatically by `modules/project` from each component's `env_random:` list
- Cloudflare Tunnel secret is now Terraform-generated via `random_password.cloudflare_tunnel_secret` (48 chars, no special) and fed into `cloudflare_zero_trust_tunnel_cloudflared.main.secret` via `base64encode`. One fewer knob in `.env`. **Migration impact on a running platform:** first `terraform apply` after merge sees the new `random_password` value and plans destroy-and-recreate of the tunnel → brief cloudflared reconnect (10-30 s Cloudflare-side blip while the new JWT propagates to the in-cluster `cloudflared` Deployment). DNS `CNAME` records update in place (target changes to the new tunnel UUID without record recreation)

### Removed
- `variable "cloudflare_zone_id"` — declared at the root but never read anywhere in `.tf` code. The tunnel resource is account-scoped; per-hostname `CNAME` records pull their zone ID from each domain's `config/domains/*.yaml` (`project_config.cloudflare_zone_id`). Operators running with `CLOUDFLARE_ZONE_ID` / `TF_VAR_cloudflare_zone_id` in `.env` can safely drop the line. Anyone passing it via `-var` or `*.tfvars` must remove the row or Terraform errors with "value for undeclared variable"
- `variable "cloudflare_tunnel_secret"` — superseded by the Terraform-owned random_password above. Drop `CLOUDFLARE_TUNNEL_SECRET` from `.env` after the first successful apply on the new code
- `variable "pod_cidr"` — declared at the root with default `10.244.0.0/16` but never read anywhere in `.tf` code and never passed down to `module "k8s"`. The actual Pod CIDR is whatever the active cluster module's own default is (`100.72.0.0/16` on `terraform-minikube-k8s` v4.0.0, `10.42.0.0/16` on k3s). Operators setting `TF_VAR_pod_cidr` in `.env` can drop it — the value never reached the cluster anyway. `-var` / `*.tfvars` users must remove the row. `BUGS.md #2` (which tracked this as known dead code) is also dropped in the same commit

### Docs
- New `## First-time Cloudflare setup` section in README — step-by-step for a zero-state Cloudflare account: create account, add site, point nameservers, locate Account ID + per-domain Zone IDs, scope a custom API Token with the three exact permissions the stack needs (`Cloudflare Tunnel: Edit`, `DNS: Edit`, `Zone: Read`), verify tunnel health after bootstrap
- Quick Start step 1 refreshed around the new `.env` layout — `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_TUNNEL_SECRET` both gone; SSH block uses the correct `TF_VAR_ssh_*` prefix (was missing — the bare `SSH_HOST`-style names the old example showed never reached Terraform)
- `.env.example`: dropped `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_TUNNEL_SECRET`; added a comment pointing at `config/domains/*.yaml` for per-domain Zone IDs
- Variables reference table in README: dropped the two removed variables
- `docs/architecture.md` Networking section: rewrote the Pod / Service CIDR claims to reflect actual module defaults on both distributions (`100.72.0.0/16` + `100.64.0.0/20` on minikube, `10.42.0.0/16` + `10.43.0.0/16` on k3s). Old "`pod_cidr` hardcoded on minikube" and "Service CIDR: `100.64.0.0/12`" were both wrong post-`terraform-minikube-k8s` v4.0.0

## [0.2.0] - 2026-04-19

Shared platform services expand beyond MySQL to cover Postgres, Redis, and Ollama, with a root-owned `platform` namespace and per-namespace ResourceQuota driven from YAML. Component model gains generic `env_random` / `env_static` / `security` patterns; routes are decoupled from components.

### Added
- Shared PostgreSQL 16 (`modules/postgres/`) — StatefulSet, `postgres-superuser` Secret, per-tenant database + role provisioned via an idempotent psql Job, credentials in each tenant's `postgres-credentials` Secret (`PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USER`, `PG_PASSWORD`, `DATABASE_URL`). Component opts in via `postgres: true`
- Shared Redis 7 (`modules/redis/`) — StatefulSet with AOF persistence + ACL enabled, `redis-default` Secret for the platform-root password. Per-tenant ACL user + `~<ns>:*` key prefix gives real cross-tenant isolation; credentials in each tenant's `redis-credentials` Secret (`REDIS_USER`, `REDIS_PASSWORD`, `REDIS_KEY_PREFIX`, `REDIS_HOST`, `REDIS_PORT`). Component opts in via `redis: true`
- Shared Ollama (`modules/ollama/`) — StatefulSet + model-pull Job (sha1-named over the models list so list changes rotate the Job), pod-level resources pulled straight from `config/platform.yaml`. Component opts in via `ollama: true`, which injects `OLLAMA_HOST` / `OLLAMA_BASE_URL` / `OLLAMA_API_BASE` through the per-tenant `ollama-endpoint` Secret. No in-cluster auth — expose publicly only through a `kind: external` component with BasicAuth
- `config/platform.yaml` toggles for each shared service (`services.{mysql,postgres,redis,ollama}.enabled`). Live file is gitignored per-operator; `.example` is tracked and ships everything off
- `config/components/chat.yaml` — Open WebUI component that proxies chat LLM calls and RAG embeddings to the shared Ollama (thin 1 Gi chat pod, heavy models held by the shared inference server)
- `config/components/ollama.yaml` — `kind: external` route so the Ollama HTTP endpoint can be exposed through Cloudflare when wanted (pair with `basic_auth: true`)
- Root-owned `platform` namespace (`platform.tf`) — shared by every service module, sized via `config/limits/platform.yaml` (12 CPU / 24 Gi on this workstation; Ollama alone can burn 10 CPU during inference)
- Per-namespace ResourceQuota via `config/limits/<ns>.yaml` — overrides `default.yaml` for the matching namespace only; keeps tenant budgets in YAML instead of TF code
- Generic component patterns in `modules/component/`:
  - `env_random: [KEY]` — Terraform generates a `random_password` per key, stores it in a per-component Secret, env_from'd into the container. Values persist in state across restarts; nothing is committed to YAML
  - `env_static: {KEY: value}` — literal env values in the component YAML
  - `security: {run_as_user, fs_group}` + auto `chown-volumes` init container for hostPath mounts (the kubelet doesn't chown hostPath for fsGroup, so the init container does it explicitly)
- `kind: external` components — route-only to a pre-existing cluster Service (Grafana in `monitoring`, Traefik dashboard via `api@internal`, shared Ollama in `platform`), no Deployment owned by the project module
- Per-component `basic_auth: true` — random password generated by Terraform, Secret + Traefik `Middleware` of kind BasicAuth, attached to the component's IngressRoute. Plaintext available via `terraform output basic_auth`
- Decoupled route model — `routes: {<host_prefix>: <component>}` in each domain YAML. Same component can back multiple hosts, different hosts can back different components; IngressRoute matches every host pointing at a given component with `Host(a) || Host(b) || …`

### Changed
- MySQL module no longer owns the `platform` namespace — it now accepts `var.namespace` and lives next to Postgres / Redis / Ollama in the root-owned namespace
- `module.mysql` adopts the `for_each = local.instances` pattern shared by the new sibling modules; disabling via `services.mysql.enabled=false` cleanly collapses every output to null and a tenant that asks for DB with MySQL off fails a precondition with a clear message
- `var.host_volume_path` is now used verbatim as the hostPath prefix by every downstream module — no regex translation, no auxiliary `local.minikube_volume_path`. The value has to match what the kubelet sees on the node, which differs by distribution (native k3s / macOS Docker-driver minikube / Linux Docker-driver minikube); the README and `docs/architecture.md` cover the three cases
- Default for `var.host_volume_path` is `/data/vol` (Linux-native scenario). macOS Docker-driver minikube operators now set `host_volume_path=/minikube-host/Shared/vol` explicitly via `.env`
- `.env.example` documents `HOST_VOLUME_PATH` with per-distribution guidance
- `terraform-k3s-k8s` module source bumped to `v0.3.1` — adds containerd registry mirrors (`mirror.gcr.io` as the docker.io default) to sidestep rate-limited image pulls, on top of the earlier v0.2.x node-registration / cert-manager fixes
- `terraform-minikube-k8s` reference in the commented Option A block bumped to `v3.0.0` — tracks the same Pod/Service CIDR and cert-manager fixes as the k3s sibling
- `./tf` wrapper reshaped into composable subcommands: `cloudflare-purge` is now a standalone verb, `bootstrap` was split by distribution into `bootstrap-minikube` (Option A, phased) and `bootstrap-k3s` (Option B, single-phase). A bare `./tf bootstrap` prints the two options and exits non-zero
- `./tf` wrapper no longer double-prefixes keys that already start with `TF_VAR_` (was a silent bug — pre-fixed keys like `TF_VAR_ssh_host` became `TF_VAR_tf_var_ssh_host` and never reached Terraform)
- `enable_traefik_dashboard=false` on the addons module — platform owns dashboard routing through the tenant YAML layer (`config/components/traefik.yaml`), the chart-side IngressRoute would otherwise create a second route on a different hostname with different auth

### Fixed
- Cloudflare tunnel teardown now force-deletes via the API (`DELETE /cfd_tunnel/<id>?force=true` with a 30 s curl timeout) on `destroy`, so the provider-level destroy doesn't block 3–5 minutes waiting for "active connections" to clear
- Cloudflare DNS cleanup in `./tf` is now scoped by the target tunnel's UUID (`endswith(<tunnel_id>.cfargotunnel.com)`) instead of the previous blanket `endswith(cfargotunnel.com)` filter. The old filter would delete CNAMEs for every tunnel on the account — including unrelated ones such as an operator's SSH-over-tunnel proxy — whenever bootstrap ran

### Removed
- `local.minikube_volume_path` and the `replace(..., "Users", "minikube-host")` heuristic

## [0.1.0] - 2026-04-18

Initial public release.

### Added
- Terraform root stack for a multi-tenant local Kubernetes hosting platform fronted by Cloudflare Zero Trust Tunnel
- Swappable cluster distribution: `module "k8s"` sources from GitHub-pinned releases
  - `terraform-minikube-k8s` `v2.1.0` — Option A (default, docker driver, Flannel, NodePort Traefik)
  - `terraform-k3s-k8s` `v0.2.0` — Option B (native k3s over SSH, `install_k3s=false` for adoption mode)
- Signature-compatible cluster modules: provider wiring is distribution-agnostic, switching the active block requires no changes to downstream code
- Root `kubernetes` / `helm` / `kubectl` providers consume `module.k8s.kubeconfig_path` via `config_path`, enabling single-phase `terraform apply` against a cold state
- Shared MySQL 8.0 StatefulSet with auto-provisioned per-tenant databases and users (`modules/mysql/`)
- Per-tenant `modules/project/` creates namespace, `ResourceQuota`, `LimitRange`, component Deployments + Services, Traefik IngressRoutes with Let's Encrypt certs, and MySQL credentials secret
- Reusable `modules/component/` (Deployment + Service + PV/PVC + ConfigMap) driven by `config/components/*.yaml`
- Tenant YAMLs under `config/domains/*.yaml` (gitignored; `.example` templates tracked)
- Cloudflare Zero Trust tunnel with hostnames dynamically aggregated from project modules, including infra services (`traefik.<infra-domain>`, `grafana.<infra-domain>`) — gracefully collapses to a catch-all rule when no tenant is configured yet
- Dedicated `cloudflared` Deployment in the `ops` namespace
- Host-volume path support for the Mac Docker-driver Minikube (`/Users/Shared/vol` mounted as `/minikube-host/Shared/vol`)
- `./tf` bootstrap wrapper with `bootstrap`, `plan`, `apply`, `destroy` subcommands
- MIT LICENSE
- Pre-commit hooks: `terraform_fmt`, `terraform_validate`, `terraform_trivy` (HIGH/CRITICAL gate), `gitleaks`, `detect-private-key`, `check-merge-conflict`
- Repository-level backend (`_backend.tf`, Backblaze B2 S3-compatible) and provider constraints (`_versions.tf`)

### Security
- `.gitignore` blocks real tenant YAMLs, `.env` files, `*.tfvars`, kubeconfigs, and local state
- `.env.example` ships only placeholders; operator credentials never enter the tree
- Git history was purged of operator-identifying strings via `git filter-repo --replace-text`
