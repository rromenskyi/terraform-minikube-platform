# Default: local state. A remote backend goes in the gitignored
# `_local_backend_override.tf`, which replaces this block (README → "Remote state").
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
