locals {
  # Hosting projects (one file = one domain)
  projects = {
    for config_file in fileset("${path.module}/config/domains", "*.yaml") :
    trimsuffix(basename(config_file), ".yaml") => yamldecode(file("${path.module}/config/domains/${config_file}"))
  }

  # Reusable component defaults
  components = {
    for config_file in fileset("${path.module}/config/components", "*.yaml") :
    trimsuffix(basename(config_file), ".yaml") => yamldecode(file("${path.module}/config/components/${config_file}"))
  }

  # Default namespace resource limits
  default_limits = yamldecode(file("${path.module}/config/limits/default.yaml"))
}
