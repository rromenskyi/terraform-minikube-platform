locals {
  # Load raw domain configs from YAML files
  _domain_configs = {
    for f in fileset("${path.module}/config/domains", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/domains/${f}"))
  }

  # Expand domain × env → one entry per project/env combination.
  # Key / namespace: "{prefix}{slug}-{env}"  (e.g. "example-com-prod")
  # Prod hostname:     "{component}.{domain}"
  # Non-prod hostname: "{component}.{env}.{domain}"
  projects = {
    for entry in flatten([
      for _, config in local._domain_configs : [
        for env in try(config.envs, ["prod"]) : {
          key                = "${config.slug}-${env}"
          name               = config.name # domain, e.g. "example.com"
          slug               = config.slug # e.g. "example-com"
          env                = env         # "prod" | "staging" | ...
          namespace          = "${var.namespace_prefix}${config.slug}-${env}"
          cloudflare_zone_id = try(config.cloudflare_zone_id, null)
          components         = try(config.components, [])
          limits             = try(config.limits, null)
        }
      ]
    ]) :
    entry.key => entry
  }

  # Reusable component definitions from config/components/*.yaml
  components = {
    for f in fileset("${path.module}/config/components", "*.yaml") :
    trimsuffix(basename(f), ".yaml") => yamldecode(file("${path.module}/config/components/${f}"))
  }

  # Default namespace resource quota
  default_limits = yamldecode(file("${path.module}/config/limits/default.yaml"))

  # Minikube Docker driver mounts /Users → /minikube-host inside the node.
  # Convert Mac host path to in-node path for hostPath volumes.
  minikube_volume_path = replace(var.host_volume_path, "Users", "minikube-host")
}
