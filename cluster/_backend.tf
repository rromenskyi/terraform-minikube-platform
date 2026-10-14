# Local state by default, like the platform stack. An operator who keeps the
# platform state remotely can add a gitignored `cluster/_local_backend_override.tf`
# with its own key; `./tf cluster ...` then takes the wrapper's lock for this
# stack's state, separate from the platform's (README, "Two stacks").
terraform {
  backend "local" {}
}
