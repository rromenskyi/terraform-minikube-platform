---
name: platform — local k3s hosting platform (terraform-minikube-platform)
description: Roman's single-operator k3s/minikube hosting platform at ~/platform. Terraform-first, multi-domain, Cloudflare Tunnel for public access, shared MySQL/Postgres/Redis/Ollama. Use this skill for anything touching ~/platform, the platform / phost-* k8s namespaces, or the Ollama LLM stack on the home node.
---

# Platform skill

You are working on **terraform-minikube-platform** — a Terraform-first
hosting platform Roman runs on his home Dell OptiPlex 7060 box. One
operator, multiple tenant domains, Cloudflare Tunnel for public access.

## When to use this skill

- Anything under `~/platform/` (the repo itself).
- Operations on the `platform`, `ops`, `monitoring`, `phost-*`, or `ingress-controller` namespaces.
- Ollama / LLM stack on the home node (the platform owns the shared Ollama).
- Cloudflare tunnel / DNS for any of Roman's tenant domains (`ipsupport.us`, `jagdterrier.club`, `paseka.co`, `priroda.kharkov.ua`).

Don't use this skill for: anything in `~/gh/sipmesh/` (separate skill at `.claude/skills/sipmesh/`); anything specific to a tenant's WordPress install (those are vanilla WordPress + MySQL).

## Repository

`~/platform/` — Git: `git@github.com:rromenskyi/terraform-minikube-platform.git`. Default branch: `main`. Active branch right now: `fix/ollama-context-length-8192`.

Two sibling repos sourced from GitHub at pinned tags (do NOT vendor — Terraform pulls them):
- `terraform-minikube-k8s` (Option A — minikube cluster module)
- `terraform-k3s-k8s` (Option B — native k3s over SSH)
- `terraform-k8s-addons` (Traefik + cert-manager + kube-prometheus-stack)

This platform is **Option B** (k3s) on Roman's box.

## Files in this skill

- **`SKILL.md`** — this file.
- **`architecture.md`** — three-layer module stack, route model, shared services, Cloudflare wiring.
- **`operating.md`** — `./tf` wrapper, env layout, daily workflows (add domain, add component, add tenant, bootstrap).
- **`troubleshooting.md`** — known boundaries, common issues, Vulkan + Arc B50 saga.

## First-class facts to remember

- **No click-ops principle**. AGENT.md is canonical-synced across four sibling repos. Everything goes through Terraform; out-of-band `kubectl edit` is a violation. Currently Ollama is in violation (manually `kubectl apply`'d Vulkan config) — plan is to backport to TF and commit, then drop the override.
- **Single operator, single trust boundary**. No NetworkPolicy, Traefik allows cross-namespace Service references. Tenants share MySQL/Postgres/Redis with per-namespace ACL credentials. Intended for cases where every tenant is something *Roman* runs.
- **Persistent storage = hostPath**. Survives cluster re-creation. `host_volume_path` defaults to `/data/vol` on this box. Multi-node would need a network-backed StorageClass.
- **Bootstrap is destructive but safe**: `./tf bootstrap-k3s` tears down the cluster + tunnel, but does NOT touch `$HOST_VOLUME_PATH` data. Re-bootstrap rotates every credential in TF state; old persistent data still has old creds → wipe the relevant volume dir to re-init.
- **Cloudflare Tunnel** replaces any need for open public ports on the host. cloudflared runs as 2-replica Deployment in `ops` namespace.
- **Ollama in `platform` namespace** is the LLM brain — chat sidecars, MCP servers, RAG embeddings all hit it via in-cluster Service `ollama.platform.svc:11434`. No auth in-cluster (trust boundary == cluster boundary).
