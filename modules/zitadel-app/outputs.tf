output "secret_name" {
  value       = kubernetes_secret_v1.oidc.metadata[0].name
  description = "Name of the Secret holding AUTH_ZITADEL_ISSUER, AUTH_ZITADEL_ID, AUTH_ZITADEL_SECRET, AUTH_SECRET — feed into the component as `oidc_secret_name`."
}

output "secret_checksum" {
  description = "SHA1 of the OIDC Secret's data, surfaced for use as a pod-template `checksum/oidc` annotation. Drives a Deployment rollout when the Zitadel app is recreated (e.g. after `terraform destroy`+`apply`, or after a manual app rotation in Zitadel) so the pod picks up the new client_id/client_secret instead of carrying the stale env from its previous start. The hash itself reveals nothing — `nonsensitive()` is used to drop the sensitivity bit so the annotation is renderable."
  value = nonsensitive(sha1(jsonencode({
    issuer        = var.issuer_url
    client_id     = zitadel_application_oidc.this.client_id
    client_secret = zitadel_application_oidc.this.client_secret
    auth_secret   = random_password.auth_secret.result
  })))
}

output "project_id" {
  value = zitadel_project.this.id
}

output "app_id" {
  value = zitadel_application_oidc.this.id
}

output "client_id" {
  value     = zitadel_application_oidc.this.client_id
  sensitive = true
}

output "client_secret" {
  value       = zitadel_application_oidc.this.client_secret
  sensitive   = true
  description = "Generated client secret for the OIDC application. Consumed directly when the downstream module renders Helm values that need the secret inline (e.g. Argo CD's Dex connector). Most kind:app components mount the AUTH_ZITADEL_SECRET key from the emitted k8s Secret instead — this output is for the rare case where Helm-time interpolation is needed."
}
