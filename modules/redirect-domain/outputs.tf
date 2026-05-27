output "ingressroute_name" {
  description = "Name of the emitted Traefik IngressRoute. Reference-only — operator can grep `kubectl get ingressroute -A` for cross-check."
  value       = "redirect-${replace(var.from_domain, ".", "-")}"
}
