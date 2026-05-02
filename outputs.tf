# ── Platform outputs ──────────────────────────────────────────────────────────

output "projects" {
  description = "Project details per namespace"
  value = {
    for k, proj in module.project : k => {
      namespace  = proj.namespace
      domain     = proj.domain
      env        = proj.env
      components = proj.components
      has_db     = proj.has_db
    }
  }
}

output "hostnames" {
  description = "All routed hostnames across projects and infra"
  value       = keys(local.all_hostnames)
}

output "tunnel_id" {
  description = "Cloudflare Tunnel ID"
  value       = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

output "tunnel_cname" {
  description = "Cloudflare Tunnel CNAME target"
  # v5 dropped the `cname` attribute on the tunnel resource; the format
  # `<tunnel-uuid>.cfargotunnel.com` is documented as stable.
  value = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
}

output "grafana_credentials" {
  description = "Grafana admin credentials (user + password)."
  value       = module.addons.grafana_credentials
  sensitive   = true
}

output "basic_auth" {
  description = "HTTP BasicAuth credentials per project → component. Populated for every component with `basic_auth: true` in its spec (e.g. the Traefik dashboard). Shape: {<project_key>: {<component>: {user, password}}}."
  sensitive   = true
  value = {
    for proj_key, proj in module.project :
    proj_key => proj.basic_auth_credentials
    if length(proj.basic_auth_credentials) > 0
  }
}

output "mysql" {
  description = "Shared MySQL connection info (host, port, namespace, service, root_password)."
  value = {
    host          = module.mysql.host
    port          = module.mysql.port
    namespace     = module.mysql.namespace
    service       = module.mysql.service_name
    root_password = module.mysql.root_password
  }
  sensitive = true
}

output "postgres" {
  description = "Shared PostgreSQL connection info (host, port, namespace, service, superuser_password)."
  value = {
    host               = module.postgres.host
    port               = module.postgres.port
    namespace          = module.postgres.namespace
    service            = module.postgres.service_name
    superuser_password = module.postgres.superuser_password
  }
  sensitive = true
}

output "redis" {
  description = "Shared Redis connection info (host, port, namespace, service, default_password). Per-tenant ACL users are provisioned inside each project — retrieve through `terraform output -json projects` or `kubectl get secret redis-credentials -n <ns>`."
  value = {
    host             = module.redis.host
    port             = module.redis.port
    namespace        = module.redis.namespace
    service          = module.redis.service_name
    default_password = module.redis.default_password
  }
  sensitive = true
}

output "ollama" {
  description = "Shared Ollama connection info (URL, namespace, pre-pulled models). No credentials — the API is unauthenticated cluster-internal; public exposure should route through BasicAuth at Traefik."
  value = {
    url       = module.ollama.url
    namespace = module.ollama.namespace
    service   = module.ollama.service_name
    port      = module.ollama.port
    models    = module.ollama.models
  }
}

output "zitadel" {
  description = "Shared Zitadel IdP — public hostname, in-cluster Service, and the bootstrap admin credentials emitted on first apply. Change the admin password in the UI on first login; the value here only stays current for as long as the random_password resource isn't replaced."
  value = {
    external_domain = module.zitadel.external_domain
    namespace       = module.zitadel.namespace
    service         = module.zitadel.service_name
    port            = module.zitadel.port
    admin_username  = module.zitadel.admin_username
    admin_password  = module.zitadel.admin_password
  }
  sensitive = true
}

output "stalwart_recovery_admin_password" {
  description = "Plaintext password for the pinned Stalwart recovery admin (username `admin`). Bypasses the OIDC directory entirely — use it whenever Zitadel sign-in is broken or unavailable. Read with `terraform output -raw stalwart_recovery_admin_password`."
  value       = module.stalwart.recovery_admin_password
  sensitive   = true
}

output "stalwart_admin_url" {
  description = "Operator-facing Stalwart admin URL. Includes a stable random URL prefix so /admin doesn't surface on the public root of mail.<domain> (which serves Roundcube webmail). Sensitive — do not paste publicly. Read with `terraform output -raw stalwart_admin_url`."
  value       = module.stalwart.admin_url
  sensitive   = true
}

output "stalwart_dkim_dns" {
  description = "DKIM record to publish under the primary mail domain. `name` is relative (`stalwart._domainkey`); paste both into `config/domains/<domain>.yaml`'s `dns:` block as type=TXT."
  value = {
    name  = module.stalwart.dkim_dns_name
    value = module.stalwart.dkim_dns_value
  }
}

output "stalwart_spf_dns" {
  description = "Recommended SPF TXT for the primary mail domain — paste under `name: \"@\"`, type: TXT in the domain yaml."
  value       = module.stalwart.spf_dns_value
}

output "stalwart_dmarc_dns" {
  description = "Recommended DMARC TXT — `name` relative (`_dmarc`), value the policy string."
  value = {
    name  = module.stalwart.dmarc_dns_name
    value = module.stalwart.dmarc_dns_value
  }
}

output "stalwart_account_url" {
  description = "Stalwart self-service account URL. Same random prefix as `stalwart_admin_url`. Mostly empty for OIDC users since password lives in Zitadel. Read with `terraform output -raw stalwart_account_url`."
  value       = module.stalwart.account_url
  sensitive   = true
}

output "zitadel_pat" {
  description = "PAT for the Zitadel TF provider (machine user `tf-platform`, IAM_OWNER, far-future expiry). Lifted from the in-cluster `zitadel-tf-pat` Secret that the FIRSTINSTANCE-bootstrapped pat-broker sidecar populates. Empty when Zitadel is disabled OR the sidecar hasn't run yet (pre-bootstrap clean clone); populated after the first `./tf apply` brings Zitadel up. Fetch with `terraform output -raw zitadel_pat`, then paste into `.env` as `TF_VAR_zitadel_pat=...` so subsequent applies provision kind:app components."
  sensitive   = true
  value = try(
    base64decode([
      for o in data.kubernetes_resources.zitadel_tf_pat_output["enabled"].objects :
      o if o.metadata.name == "zitadel-tf-pat"
    ][0].data.access_token),
    ""
  )
}

output "namespaces" {
  description = "All project namespaces managed by this platform."
  value       = [for _, proj in module.project : proj.namespace]
}

output "cheatsheet" {
  description = "Common commands for working with the platform."
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════╗
    ║                     Platform Cheatsheet                      ║
    ╚══════════════════════════════════════════════════════════════╝

    ── Secrets ────────────────────────────────────────────────────
    Grafana admin password:
      terraform output -json grafana_credentials | jq -r '.password'

    MySQL root password:
      terraform output -json mysql | jq -r '.root_password'

    PostgreSQL superuser password:
      terraform output -json postgres | jq -r '.superuser_password'

    Redis default-user password (platform-root; tenants use their own
    ACL user, password in the per-namespace `redis-credentials` Secret):
      terraform output -json redis | jq -r '.default_password'

    Stalwart recovery admin (bypasses OIDC; user `admin`):
      terraform output -raw stalwart_recovery_admin_password

    Mail — Roundcube webmail (Zitadel SSO; auto-provisions Stalwart UserAccount on first login):
      https://${try(local.mail.hostname, "<configure mail in a domain yaml>")}/

    Mail — Stalwart admin panel (operator-only; URL hidden behind a random prefix
    so the login screen doesn't surface to drive-by scans — paste from the
    output, never share):
      terraform output -raw stalwart_admin_url

    Mail — Stalwart self-service /account (mostly empty for OIDC users):
      terraform output -raw stalwart_account_url

    Mail — DKIM/SPF/DMARC DNS records to add to config/domains/<domain>.yaml dns:
      terraform output stalwart_dkim_dns    # name+value (TXT)
      terraform output -raw stalwart_spf_dns
      terraform output stalwart_dmarc_dns   # name+value (TXT)

    Traefik dashboard login (user: admin):
      terraform output -json basic_auth \
        | jq -r '[.[].traefik?.password] | map(select(.)) | .[0]'

    Every BasicAuth credential (Traefik dashboard + any other
    `basic_auth: true` component):
      terraform output -json basic_auth | jq

    Per-project DB credentials (created when a component has `db: true`):
      kubectl get secret db-credentials -n <namespace> -o json \
        | jq '.data | map_values(@base64d)'

    Per-project PostgreSQL credentials (created when a component has `postgres: true`):
      kubectl get secret postgres-credentials -n <namespace> -o json \
        | jq '.data | map_values(@base64d)'

    Per-project Redis credentials (created when a component has `redis: true`):
      kubectl get secret redis-credentials -n <namespace> -o json \
        | jq '.data | map_values(@base64d)'

    Ollama URL (cluster-internal, injected as OLLAMA_HOST when a
    component sets `ollama: true`):
      terraform output -json ollama | jq -r '.url'

    Quick test from the host:
      kubectl run curlollama --image=curlimages/curl --rm -it --restart=Never \
        -n platform -- curl -s http://ollama.platform.svc.cluster.local:11434/api/tags

    ── MySQL ──────────────────────────────────────────────────────
    Connect to MySQL (run inside the mysql pod):
      kubectl exec -it statefulset/mysql -n ${module.mysql.namespace} -- \
        sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

    List databases:
      kubectl exec statefulset/mysql -n ${module.mysql.namespace} -- \
        sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"'

    ── Host storage ───────────────────────────────────────────────
    Every hostPath PV lives under `${var.host_volume_path}`:
      ${var.host_volume_path}/${module.mysql.namespace}/mysql/   — MySQL data
      ${var.host_volume_path}/<namespace>/<component>/<mount>    — project data

    ── Debugging ──────────────────────────────────────────────────
    Pods in every project namespace (label-filtered across the cluster):
      kubectl get pods -A -l app.kubernetes.io/managed-by=terraform

    Pods in a single project:
      kubectl get pods -n <namespace>

    Logs / shell for a component:
      kubectl logs -f deploy/<component> -n <namespace>
      kubectl exec  -it deploy/<component> -n <namespace> -- sh

    ── Terraform ──────────────────────────────────────────────────
    Plan:       ./tf plan
    Apply:      ./tf apply
    Bootstrap:  ./tf bootstrap-k3s      (or: ./tf bootstrap-minikube)
    Purge CF:   ./tf cloudflare-purge   (DESTRUCTIVE: nukes tunnel + DNS)
    Outputs:    terraform output
    Projects:   terraform output -json projects | jq .

  EOT
}
