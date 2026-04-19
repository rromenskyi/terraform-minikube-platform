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
  value       = cloudflare_zero_trust_tunnel_cloudflared.main.cname
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

    Traefik dashboard login (user: admin):
      terraform output -json basic_auth \
        | jq -r '[.[].traefik?.password] | map(select(.)) | .[0]'

    Every BasicAuth credential (Traefik dashboard + any other
    `basic_auth: true` component):
      terraform output -json basic_auth | jq

    Per-project DB credentials (created when a component has `db: true`):
      kubectl get secret db-credentials -n <namespace> -o json \
        | jq '.data | map_values(@base64d)'

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
    Purge CF:   ./tf cloudflare-purge
    Outputs:    terraform output
    Projects:   terraform output -json projects | jq .

  EOT
}
