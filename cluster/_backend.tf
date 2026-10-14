# Local state by default, like the platform stack. An operator who keeps the
# platform state remotely can add a gitignored `cluster/_local_backend_override.tf`
# with its own key. The `./tf` wrapper's B2 state lock covers the platform
# stack only; this stack is applied from one machine (README, "Two stacks").
terraform {
  backend "local" {}
}
