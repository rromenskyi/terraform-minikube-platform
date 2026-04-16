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
  description = "Grafana admin credentials"
  value       = module.k8s.grafana_credentials
  sensitive   = true
}

output "mysql" {
  description = "Shared MySQL connection info"
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
  description = "All project namespaces"
  value       = [for _, proj in module.project : proj.namespace]
}

output "cheatsheet" {
  description = "Common commands for working with the platform"
  value       = <<-EOT

    ╔══════════════════════════════════════════════════════════════╗
    ║                    Platform Cheatsheet                      ║
    ╚══════════════════════════════════════════════════════════════╝

    ── Secrets ────────────────────────────────────────────────────
    MySQL root password:
      terraform output -json mysql | jq -r '.root_password'

    Grafana admin password:
      terraform output -json grafana_credentials | jq -r '.password'

    DB credentials for a project namespace:
      kubectl get secret db-credentials -n <namespace> -o json \
        | jq '.data | map_values(@base64d)'

    ── Dashboards ─────────────────────────────────────────────────
    Kubernetes dashboard:
      minikube dashboard -p ${var.cluster_name}

    Grafana (port-forward):
      kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

    Traefik dashboard (port-forward):
      kubectl port-forward svc/traefik 9000:9000 -n ingress-controller

    ── MySQL ──────────────────────────────────────────────────────
    Connect to MySQL from host:
      kubectl exec -it statefulset/mysql -n ${module.mysql.namespace} -- \
        sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

    List databases:
      kubectl exec statefulset/mysql -n ${module.mysql.namespace} -- \
        sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW DATABASES;"'

    ── Storage ────────────────────────────────────────────────────
    Host path (Mac):
      ${var.host_volume_path}/

    In-node path (minikube):
      ${local.minikube_volume_path}/

    Structure:
      ${var.host_volume_path}/<namespace>/              — project data
      ${var.host_volume_path}/${module.mysql.namespace}/mysql/   — MySQL data

    Browse MySQL data:
      ls ${var.host_volume_path}/${module.mysql.namespace}/mysql/

    Browse WordPress uploads:
      ls ${var.host_volume_path}/<namespace>/wordpress/var-www-html-wp-content/

    ── Debugging ──────────────────────────────────────────────────
    All pods across project namespaces:
      kubectl get pods ${join(" ", [for ns in [for _, p in module.project : p.namespace] : "-n ${ns}"])}

    Pod logs:
      kubectl logs -f deploy/<component> -n <namespace>

    Shell into a pod:
      kubectl exec -it deploy/<component> -n <namespace> -- sh

    ── Terraform ──────────────────────────────────────────────────
    Plan:           ./tf plan
    Apply:          ./tf apply
    Full bootstrap: ./tf bootstrap
    Show outputs:   terraform output
    Show projects:  terraform output -json projects | jq .

  EOT
}
