# airllm

One instance of [AirLLM](https://github.com/ipsupport-llc/ipsupport-airllm),
a self-hosted LLM gateway, deployed from its public Helm chart by an Argo CD
Application. Call it once per environment (for example a release-pinned
instance and a development instance tracking `main`).

## Shape

- **Application.** Argo CD tracks `chart_revision` of the app repo. On `main`
  it also reads `deploy/argocd/values-main.yaml`, the image digests the app
  repo's CI commits after every green build, so a merge there is the rollout.
  On a release tag (`vX.Y.Z`) the image follows the tag's appVersion. The
  Application belongs to the `platform` AppProject, which must admit
  `repo_url` and `namespace`.
- **Database.** A Job creates the role and database `database_name` on the
  shared Postgres. With `seed_from_database`, a second Job copies that
  database into the new one once, while the new one has no tables; it never
  overwrites data written since. A copy carries provider credentials encrypted
  with the source instance's master key, so pass that key as `master_key`.
- **Redis.** Each instance has its own ACL user. The app's keys always start
  with `air:`, so two instances on one Redis need different `redis_db`
  indexes, or they share usage counters, locks and breaker state.
- **Runtime Secret** `<name>-secrets` (the chart's `existingSecret`):
  `database-url`, `redis-url`, `master-key`, `session-key`,
  `admin-password`, plus `oidc-client-secret` with `oidc`.
- **Login.** Without `oidc`, local accounts with a bootstrap `admin`. With
  `oidc`, login goes through the identity provider only (the app has no
  password login in that mode); `role_map` decides who gets `airllm_admin`
  or `airllm_user`.
- **Exposure.** With `hostname`: an unproxied Cloudflare A record to
  `public_ip`, a Let's Encrypt certificate, and Traefik IngressRoutes (HTTPS,
  plus an HTTP→HTTPS redirect).
- **GCP.** With `google_service_account`, the pod impersonates that SA
  through the cluster's Workload Identity Federation pool (`gcp_wif_audience`)
  for the gateway's Google provider kinds. The SA must trust
  `system:serviceaccount:<namespace>:<name>`.

## Usage

```hcl
module "airllm_dev" {
  source = "./modules/airllm"

  enabled   = true
  name      = "airllm-dev"
  namespace = "airllm-dev"
  app_env   = "dev"
  replicas  = 1

  dashboards_enabled      = false # the chart's dashboard uids are fixed
  prometheus_rule_enabled = false

  argocd_namespace          = "argocd"
  setup_namespace           = "platform"
  postgres_host             = module.postgres.host
  postgres_superuser_secret = module.postgres.superuser_secret_name
  database_name             = "airllm_dev"
  seed_from_database        = "airllm"
  master_key                = module.airllm.master_key
  redis_host                = module.redis.host
  redis_port                = module.redis.port
  redis_db                  = 1
  redis_acl_namespace       = module.redis.acl_namespace

  oidc = {
    issuer      = "https://id.example.com"
    client_id   = module.airllm_dev_oidc.client_id
    roles_claim = "groups"
    role_map    = "airllm_dev_admin:airllm_admin,airllm_dev_user:airllm_user"
  }
  oidc_client_secret = module.airllm_dev_oidc.client_secret

  hostname           = "airllm-dev.example.com"
  cloudflare_zone_id = var.zone_id
  public_ip          = "203.0.113.10"
}
```

## Known limits

- The chart has no pod annotations, so a changed client secret (a recreated
  identity-provider app) reaches the pod only on its next restart.
