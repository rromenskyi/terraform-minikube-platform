# Deploying an application with Argo CD

This runbook takes an application that lives in its own repository — its
own image, Helm chart and CI — and runs it on the platform. The platform
provides the namespace, the public route, TLS, backing services and secrets.
The application repository owns everything inside its Pods.

The example below deploys `my-app`, a single HTTP service, into the `prod`
environment of the `example.com` project and serves it under
`https://example.com/api`.

## Division of responsibilities

| Concern | Owner | Where |
|---|---|---|
| Namespace, quota, LimitRange | platform | domain yaml, `envs.<env>` |
| Argo CD AppProject + bootstrap Application | platform | `argocd_bootstraps:` |
| Public hostname, path, TLS, CDN tunnel | platform | `routes:` + an external component |
| Postgres / MySQL / Redis / Ollama credentials | platform | `shared_services:` |
| Registry pull credential | platform (value in Vault) | `image_pull_secrets:` |
| Application secrets | platform (generated or in Vault) | `secrets:` |
| Deployment, Service, probes, metrics | application | Helm chart in the app repo |
| Image build and rollout trigger | application | CI in the app repo |

Keep this split. A chart that ships its own Ingress, or a platform yaml that
knows about a Pod's internals, makes every later change harder.

## 1. Application repository layout

```
Dockerfile
deploy/
  helm/my-app/                     # the chart
    Chart.yaml
    values.yaml                    # generic defaults, no environment facts
    templates/
  argocd/
    apps/application-prod.yaml     # Argo CD Application(s), one per env
    values/values-prod.yaml        # environment overlay
.github/workflows/ci.yml
```

The platform's bootstrap Application points at `deploy/argocd/apps` and
syncs every Application manifest it finds there (app-of-apps).

### The Application manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  # Must be the AppProject the platform creates: it is named exactly
  # like the target namespace. Anything else is refused.
  project: <namespace>
  source:
    repoURL: https://github.com/<owner>/my-app     # same URL as in argocd_bootstraps
    targetRevision: main
    path: deploy/helm/my-app
    helm:
      releaseName: my-app
      valueFiles:
        - ../../argocd/values/values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: <namespace>
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=false]
```

The namespace is `<namespace_prefix><slug>-<env>`, e.g.
`phost-example-com-prod` with the default prefix. The platform creates it,
so the Application must not (`CreateNamespace=false`).

The AppProject only allows namespaced resources in that namespace. CRDs,
ClusterRoles and other cluster-scoped objects belong to the platform.

## 2. Chart guidelines

- **No Ingress or IngressRoute.** The platform routes traffic to a Service
  (step 4). The chart exposes a `ClusterIP` Service with a named port.
- **Stable Service name.** The platform's route refers to it by name, so pin
  it with `fullnameOverride` in the environment overlay.
- **Configuration from Secrets through `envFrom`.** Let the overlay list the
  Secret names (`envFromSecrets: [postgres-credentials, …]`) rather than
  hard-coding them in templates, so the chart stays portable.
- **Image by digest.** Render `repository@digest` when a digest is set and
  fall back to a tag otherwise. CI writes the digest (step 3).
- **Pull secret.** Reference the platform-provisioned pull Secret in
  `imagePullSecrets`. The platform also attaches it to the namespace's
  `default` ServiceAccount.
- **Restricted security context.** Non-root, `readOnlyRootFilesystem`, all
  capabilities dropped, `RuntimeDefault` seccomp,
  `automountServiceAccountToken: false` unless the app calls the API server.
- **Probes.** A cheap liveness endpoint, and a readiness endpoint that
  checks the app's hard dependencies (usually the database).
- **Metrics.** Serve Prometheus metrics on a separate port and ship an
  optional `ServiceMonitor` behind a values flag. The cluster's Prometheus
  selects ServiceMonitors in every namespace without extra labels.
- **Placement.** Set `nodeSelector` in the overlay if the cluster uses node
  tiers; leave the chart default empty.

## 3. CI

A typical pipeline on self-hosted runners:

1. **Test**: build, `go vet` / linters, formatting, unit tests,
   vulnerability scan. Integration tests that need a database install it
   inline; runner Pods are usually unprivileged, so service containers are
   not available.
2. **Lint the chart**: `helm lint` and `helm template` with each overlay.
3. **Build and push** the image on the default branch, tagged with the
   commit SHA (and `latest` if you like). Use the cluster's remote BuildKit
   if runners cannot run Docker.
4. **Bump the digest**: resolve the pushed image's digest (`crane digest`),
   write it into `deploy/argocd/values/values-<env>.yaml` with `yq`, commit
   with `[skip ci]` and push. Argo CD notices the commit and rolls the
   Deployment. If the default branch is protected, push with a GitHub App
   token for an App that may bypass the protection, and store its ID and
   private key as repository secrets.

The commit that bumps the digest is the deployment record: `git log` on the
values file shows what ran when.

## 4. Platform configuration

All of this goes under `envs.<env>` of the project's domain yaml.

### Argo CD bootstrap

```yaml
argocd_bootstraps:
  my-app:
    repo_url:                 "https://github.com/<owner>/my-app"
    path:                     deploy/argocd/apps
    target_revision:          main
    # GitHub App mode (one App, many repos). SSH deploy keys are the
    # alternative; see the README.
    repo_app_pem_id:          <pem-id>
    repo_app_id:              "<app id>"
    repo_app_installation_id: "<installation id>"
```

This creates the AppProject, a repository credential and the bootstrap
Application. The App's private key is read from Vault at
`secret/data/tenants/<slug>/argocd-github-apps/<pem-id>` (key
`githubAppPrivateKey`). Each tenant has its own copy under its own prefix.

### Registry pull credential

```yaml
image_pull_secrets:
  ghcr-pull:
    registry: ghcr.io
```

Upload `username` and `token` to
`secret/data/tenants/<slug>/image-pull-secrets/ghcr-pull`. The platform
renders a `dockerconfigjson` Secret named `ghcr-pull`.

### Backing services

```yaml
shared_services:
  postgres: true     # Secret postgres-credentials: DATABASE_URL, PG_HOST, PG_USER, …
  redis:    false    # Secret redis-credentials
  db:       false    # MySQL, Secret db-credentials
  ollama:   false    # Secret ollama-endpoint: OLLAMA_HOST, OLLAMA_BASE_URL
```

Each enabled service gets a per-namespace database/user and a Secret with a
fixed name that the chart consumes through `envFrom`.

### Application secrets

```yaml
secrets:
  my-app-secret:
    keys: [SECRET_KEY]          # engine-generated random value
  my-app-vendor:
    vault: true                 # value(s) uploaded to Vault by the tenant
```

A random secret is generated once and kept in Terraform state. Rotating it
means tainting the generator on purpose, and consumers must be restarted
because Secret changes do not restart Pods.

### Public route

Declare an external component that points at the chart's Service. It is
specific to this project, so it goes inline under `envs.<env>.components`
rather than into the shared `config/components/` templates:

```yaml
components:
  my-app:
    kind: external
    service:
      name:      my-app              # the chart's fullnameOverride
      namespace: <namespace>
      port:      8080
```

Then route to it:

```yaml
routes:
  "":      web       # the site itself, on the apex host
  "/api":  my-app    # example.com/api and example.com/api/* → my-app
  app:     my-app    # alternatively, a whole host: app.example.com
```

A key with a slash is a path route: `"/api"` is the apex host, `"app/api"`
the `app.` host. Path routes get a higher Traefik priority than whole-host
routes, so `/api` on a host keeps working when that host also has a site.
The path is not stripped: the application receives `/api/...` and should
route on the full path.

Traffic arrives through the Cloudflare Tunnel. The real client address is
in the `CF-Connecting-IP` header; the socket peer is the in-cluster proxy.
Use that header for rate limiting or logging, and do not expose the Service
any other way, or the header can be forged.

The platform's fallback-error middleware replaces only 502/503/504
responses with a branded page. Other status codes and bodies reach the
client untouched.

### Sending mail from the app (optional)

Apps can submit mail to the in-cluster mail server on port 25 without
authentication. To keep such messages out of the spam filter, list the
EHLO name the app uses under the mail domain's `trusted_helo_domains:`.
If the app needs its own address, add a forward-only alias under
`aliases:`.

## 5. Roll out

1. Push the application repository (chart, Application, CI). Let CI publish
   the first image.
2. Upload the Vault values the configuration refers to (GitHub App key, pull
   credential, any `vault: true` secrets).
3. `./tf plan`, check that it only adds what you expect, then `./tf apply`.
4. In Argo CD the bootstrap Application and then `my-app-prod` appear and
   sync. Until the Vault values are present, the repository credential or
   the pull Secret stays unsynced and the app shows `ImagePullBackOff` or a
   repository error. That is expected and clears once the values exist.

## 6. Verify

- Argo CD: both Applications `Synced` and `Healthy`.
- `kubectl -n <namespace> get pods` shows Pods `Running` and ready.
- The public URL answers through the CDN, e.g.
  `curl -i https://example.com/api/...`.
- Error responses come back with the app's own body, not a platform page.
- Prometheus has the target `UP` if a ServiceMonitor is enabled.
- For a mail-sending app, a test message lands in the inbox, not in Junk.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Application `Unknown`, "repository not accessible" | GitHub App key missing in Vault for this tenant, or the App not installed on the repo |
| "application destination … is not permitted in project" | `spec.project` is not the namespace name, or the destination namespace differs |
| `ImagePullBackOff` | pull credential missing in Vault or lacking the packages scope |
| Public URL returns the platform's fallback page | Service name or port in the external component does not match the chart |
| 404 from Traefik for `/api` | route not applied, or the request host differs from the routed host |
| Pods crash-loop right after deploy | a required Secret key is missing; check the container log, validation errors name the variable |
| New secret value not picked up | Secret changes do not restart Pods; roll the Deployment |
