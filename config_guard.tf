# Refuse to plan against an incomplete configuration.
#
# Operator configuration is gitignored, and the engine falls back to empty
# defaults when it is missing (`local._platform_raw`, `local._domain_configs`).
# Against an existing state that fallback is a destructive desired state:
# a fresh clone, a wrong working directory or a lost config file would plan
# to disable every service and delete every project. Preconditions fail the
# plan instead. A brand-new install with no config yet sets
# `allow_missing_config = true` once.

variable "allow_missing_config" {
  description = "Allow planning without `config/platform.yaml` or without any `config/domains/*.yaml` (empty defaults). Only for a first install or an intentional teardown; otherwise a missing config would plan to remove everything."
  type        = bool
  default     = false
}

resource "terraform_data" "config_guard" {
  lifecycle {
    precondition {
      condition     = var.allow_missing_config || fileexists(local._platform_file)
      error_message = "config/platform.yaml is missing. Planning without it would disable every service. Restore the file (see config/platform.yaml.example), or set allow_missing_config = true for a first install / intentional teardown."
    }
    precondition {
      condition     = var.allow_missing_config || length(local._domain_configs) > 0
      error_message = "No config/domains/*.yaml found. Planning without them would delete every project. Restore them (see config/domains/example.com.yaml.example), or set allow_missing_config = true for a first install / intentional teardown."
    }
  }
}
