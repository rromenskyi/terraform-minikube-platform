# platform — troubleshooting

Triage in this order: terraform / cluster bring-up → Cloudflare tunnel → tenant routing → component health → Ollama.

## Terraform / cluster bring-up

| Symptom | Likely cause | First check |
|---|---|---|
| `terraform apply` hangs at "destroying tunnel" 3-5 minutes | provider waits for "active connections to clear" | The destroy-time `null_resource.cloudflare_tunnel_force_delete` handles this with `DELETE /cfd_tunnel/<id>?force=true`. If it's still hanging, the API token was rejected (token in `triggers` is sensitive → output suppressed; see BUGS.md #1) |
| Bootstrap aborts: "tunnel with name X already exists in your account" | Previous bootstrap state was wiped but the tunnel survived on Cloudflare side | `./tf cloudflare-purge` (nuke) OR `terraform import cloudflare_zero_trust_tunnel_cloudflared.main <id>` (adopt) |
| Bootstrap fails on first `terraform apply`: "CRD not found" for IngressRoute | Plan tried to validate IngressRoute against a fresh cluster before Traefik installed its CRDs | We use `kubectl_manifest` (not `kubernetes_manifest`) precisely to avoid plan-time CRD lookup. If this fires, check that all IngressRoute resources are `kubectl_manifest "..."`, not `kubernetes_manifest`. |
| `./tf` doesn't load env / TF vars are missing | `.env` not at `~/platform/.env` OR variable was added after wrapper sourced | Re-run; the wrapper re-sources `.env` per invocation |
| `pre-commit` complains about CHANGELOG / terraform-docs | Required by AGENT.md standards | Run `terraform-docs markdown` per touched module + add a CHANGELOG entry under `## [Unreleased]` |
| State has Cloudflare resources that don't exist on the API side | Manual deletion in Cloudflare dashboard while TF state was disconnected | `terraform state rm <addr>` for each ghost OR `terraform import <addr> <id>` to re-adopt |

## Cloudflare tunnel

| Symptom | Likely cause | First check |
|---|---|---|
| `cloudflared` pods are CrashLoopBackOff | tunnel JWT token mismatch (rotated by re-bootstrap) | `kubectl -n ops logs deployment/cloudflared` — looks for "Unauthorized" / "no such tunnel". `terraform apply` to refresh the token Secret. |
| All tenant URLs return Cloudflare 1033 | tunnel offline | `cloudflared` pods running? `kubectl -n ops get pods -l app=cloudflared`. If yes, check tunnel status in Cloudflare dashboard — tunnels page should show "HEALTHY" |
| One specific URL returns 404 / wrong content | DNS CNAME points at wrong tunnel OR tunnel ingress rule missing | `dig +short <hostname>` should be `<tunnel-id>.cfargotunnel.com`. Check the tunnel's ingress config matches what's in `cloudflare.tf` (run `./tf state show 'cloudflare_zero_trust_tunnel_cloudflared.main'`) |
| New domain's CNAME records didn't get created | Wrong `cloudflare_zone_id` in the domain YAML | Cross-check zone ID in Cloudflare dashboard → Domain Overview → "API → Zone ID" |
| Cloudflare cleanup wiped unrelated CNAMEs | `./tf cloudflare-purge` filter was too broad in older versions (now scoped by tunnel UUID) | Should NOT happen on current code. If it does, `./tf` script must be re-checking the `endswith(<tunnel_id>.cfargotunnel.com)` scope |

## Tenant routing / Traefik

| Symptom | Likely cause | First check |
|---|---|---|
| 404 on a tenant URL | IngressRoute missing or wrong host match | `kubectl get ingressroute -A | grep <tenant>` — match clauses should be `Host("a") || Host("b")` for every route pointing at a component |
| 401 on a route that shouldn't have BasicAuth | Wrong component has `basic_auth: true` | `kubectl -n <ns> get middleware`; the IngressRoute should NOT reference the `<component>-basic-auth` Middleware unless the YAML opted in |
| Traefik dashboard at `traefik.<domain>` unreachable | The dashboard component is `kind: external` → `api@internal`, served by Traefik itself | Verify `enable_traefik_dashboard=false` is set on the addons module — otherwise the chart creates its own dashboard route conflicting with the platform's |
| External component (Grafana, Ollama) returns "Service Unavailable" | Cross-namespace Service reference blocked | Traefik must have `providers.kubernetesCRD.allowCrossNamespace=true` (set by addons module). If `false`, all `kind: external` cross-ns refs break |

## Component health

| Symptom | Likely cause | First check |
|---|---|---|
| Pod CrashLoopBackOff with permission-denied on volume | hostPath PV not chowned to `fs_group` | The component module auto-creates a `chown-volumes` init container when `security.fs_group` is set. Check that `fs_group:` is in the YAML. If not, add it. |
| Pod stuck in Pending forever | Quota exceeded for the namespace | `kubectl describe quota -n <ns>` — current vs hard. Bump in `config/limits/<ns>.yaml` or domain YAML's `envs.<env>.limits` |
| `random_password` in TF state but not visible in Pod | Component reads via env_from but key absent in spec | env_random keys are emitted as explicit `env` entries (not env_from) since the unreleased change — confirm `kubectl describe pod` shows `valueFrom: secretKeyRef: name=<comp>-random-env key=<KEY>` |
| `:latest` images don't refresh after rebuild | k8s default `IfNotPresent` policy for moving tags | Component module auto-derives `imagePullPolicy: Always` for `:latest` / empty / digest-pinned. If it didn't, set `image_pull_policy: Always` explicitly |
| Sidecar can't reach main container on `127.0.0.1` | Sidecars share network ns with main — should always work | If failing, the main container probably isn't bound to `0.0.0.0` (bound to `localhost` only? check `MCP_HOST: 127.0.0.1` etc) |

## Ollama / Arc B50 saga

The Arc B50 GPU situation is the platform's most painful integration. Memory entries `project_arc_b50_ollama_sycl.md` and `project_ollama_k8s_setup.md` track the full backlog.

| Symptom | Likely cause | First check |
|---|---|---|
| Ollama pod runs but `ollama list` shows `cpu` library | Backend didn't load | `kubectl -n platform logs ollama-0 | grep -i 'library=\|backend\|vulkan\|sycl'`. With Vulkan: should see `library=vulkan` or device-found line. With SYCL fork: must see `library=sycl0` |
| Generation throughput stuck around 6 t/s on Arc B50 | 256 MB BAR ceiling — the GPU's full VRAM is unreachable without rBAR | This is the **known hardware boundary**. UEFI doesn't expose Resizable BAR toggle on this Dell. ReBarUEFI mod = brick risk, not attempting. DSDT override path untried. |
| `ollama pull qwen3.5:9b` returns HTTP 412 | Model manifest schema newer than the runtime | Stock `ollama/ollama:0.21.1` parses fine. Intel IPEX-LLM fork ships `ollama 0.9.3` and chokes on qwen35 / gemma4 — pull-Job logs `SKIP <model>` instead of failing |
| `ollama pull` succeeds but model never loads | Image's runtime has the manifest but missing backend symbol | Specific to community SYCL forks: `0deep/ollama-for-intel-gpu` v0.20.5 has `libggml-sycl.so` but missing `ggml_backend_score` symbol → `load_best()` silently drops it. Use `goodmartian/ollama-intel-sycl:v0.18.2` instead (three-line patch fixes the symbol) |
| Vulkan picks the wrong GPU (UHD 630 instead of Arc) | Default device selection picks index 0 | Set `MESA_VK_DEVICE_SELECT=8086:e212` (Arc Pro B50 PCI ID). Live config has this already |
| SYCL device selector picks wrong GPU | `ONEAPI_DEVICE_SELECTOR=level_zero:0` pins device index | Use `level_zero:gpu` to let the runtime pick the higher-VRAM device — historically picked iGPU when pinned to index 0 |
| Tool calls return empty (`tool_calls: []`) | Prompt got truncated past the default 4096 ctx window | `OLLAMA_CONTEXT_LENGTH` defaults bumped to 8192 in current TF. mcp-weather-simple's catalog is ~4500 tokens; chopped at 4096 hides later tool schemas. Tell in logs: `truncating input prompt limit=4096 prompt=<N>` |
| Prefix cache cold on every chat → slow first turn | Default keep-alive too short | `OLLAMA_KEEP_ALIVE=24h` keeps models resident. Live config has this |

## Open WebUI / chat sidecars

| Symptom | Likely cause | First check |
|---|---|---|
| Chat shows tool servers as "Not Verified" / no tools available | Upstream bug `open-webui/open-webui#18140` — `TOOL_SERVER_CONNECTIONS` requires one manual "Verify + Save" click on first volume init | One-time click in Admin → Settings → External Tools. Persists in SQLite afterward. Auto-fix is a planned `kubernetes_job_v1` calling the admin API |
| Open WebUI startup fails with Permission denied on `.webui_secret_key` | UID 1000 can't write to `/app/backend` (baked into image) | `WEBUI_SECRET_KEY` env must be set so the file-write path is skipped. Provided by `env_random` in chat.yaml |
| Open Terminal sidecar fails to start with iptables errors | The Alpine image's hardened entrypoint tries to set up iptables egress firewall — needs root | Component overrides `command: ["open-terminal"]` to bypass the entrypoint. NetworkPolicy is our actual egress boundary anyway |

## Storage / data

| Symptom | Likely cause | First check |
|---|---|---|
| After `bootstrap-k3s`, app reports "wrong password" on DB | DB credentials were rotated by `random_password` in fresh state, but the persistent volume retained the old grants | Either restore the old `random_password` from a TF state backup OR wipe `<host_volume_path>/<namespace>/<component>/` and let the setup Job re-init |
| PVC stuck Pending | hostPath provisioner not happy — wrong path on host | Confirm `$HOST_VOLUME_PATH` matches what the kubelet sees. On native k3s = literal host path. On macOS Docker-driver minikube = `/minikube-host/...`. On Linux Docker-driver minikube = need explicit `minikube mount` |

## Useful one-liners

```bash
# Watch a tenant's pod come up
kubectl -n phost-<slug>-<env> get pods -w

# Live logs of a chat pod
kubectl -n phost-<slug>-<env> logs -f deployment/chat -c chat

# Inspect a sidecar
kubectl -n phost-<slug>-<env> logs -f deployment/chat -c mcp-weather

# Pull a tenant's BasicAuth password
terraform output -raw basic_auth | jq -r '.[<tenant>]'

# Rotate the chat random env (forces Pod restart with new creds)
kubectl -n phost-<slug>-<env> delete secret chat-random-env
terraform apply  # regenerates + restarts chat

# What did kubectl-applied vs TF-applied this resource?
kubectl get sts ollama -n platform -o jsonpath='{.metadata.annotations}' | jq

# All persistent data on disk
ls /data/vol/

# Shell into a pod with no shell (use ephemeral debug container)
kubectl debug -it pod/<name> --image=alpine --target=<container>
```

## When to escalate vs. dig in

Triage these yourself: tunnel offline, single tenant 404, single Pod CrashLoop, model pull failure, chat doesn't see tools, DB connection refused.

Escalate / take to design: anything that smells like the trust model breaking — cross-tenant data exposure, NetworkPolicy needing introduction, multi-node migration. These are platform-level architectural decisions, not bug fixes.
