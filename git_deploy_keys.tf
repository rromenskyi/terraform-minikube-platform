# SSH deploy keys for `git_sync`-enabled components.
#
# `git_sync` sidecars pull from private git repositories over SSH.
# Each pull needs an SSH private key + a `known_hosts` entry the
# remote (GitHub / GitLab / self-hosted) won't change. This file
# turns operator-supplied keys (set in a gitignored
# `terraform.tfvars` or `.auto.tfvars`) into a per-namespace k8s
# Secret named `git-deploy-key-<id>`. Components reference it via
# `git_sync.ssh_key_secret_name`.
#
# `known_hosts` is rendered uniformly from a static list keyed by
# the host's literal `<host> <key-type> <pubkey>` line — GitHub /
# GitLab / SourceHut / Bitbucket fingerprints are stable across
# years, baking them in saves the operator from scraping
# `ssh-keyscan` output for every new repo.

variable "git_deploy_keys" {
  description = "Map of git deploy keys consumed by `git_sync`-enabled components. Key = arbitrary identifier appearing in the rendered Secret name (`git-deploy-key-<id>`); component yaml references it via `git_sync.ssh_key_secret_name: git-deploy-key-<id>`. Value carries the target namespace, the SSH private key (the matching public half goes in the GitHub repo's deploy-keys settings, read-only is enough for git-sync), and the host the key talks to (used to pick the right `known_hosts` line). NOT marked `sensitive = true` at the variable level because TF then refuses `for_each` over the map keys; `kubernetes_secret_v1` already marks the rendered Secret's `data` block sensitive in state."
  type = map(object({
    namespace      = string
    ssh_privatekey = string
    host           = optional(string, "github.com")
  }))
  default = {}
}

locals {
  # Curated `known_hosts` for the most common git hosts. Add a
  # line here when a new host gets used; far simpler than asking
  # every operator to pipe `ssh-keyscan` into a tfvars value.
  # Values lifted from each host's published SSH fingerprints.
  _known_hosts = {
    "github.com"    = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    "gitlab.com"    = "gitlab.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf"
    "git.sr.ht"     = "git.sr.ht ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDZ+l/lvYmaeOAPeijHL8d4794Am0MOvmXPyvHTtrqvgmvCJB8pen/qkQX2S1fgl9VkMGSNxbp7NF7HmKgs5ajTGV9mB5A5zq+161lcp5+f1qmn3Dp1MWKp/AzejWXKW+dwPBd3kkudDBA1fa3uK6g1gK5nLw3qcuv/V5oGv2DOX0ge4dQVtUkUoFlqUr posthog@TheServer"
    "bitbucket.org" = "bitbucket.org ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIazEu89wgQZ4bqs3d63QSMzYVa0MuJ2e2gKTKqu+UUO"
  }
}

resource "kubernetes_secret_v1" "git_deploy_key" {
  for_each = var.git_deploy_keys

  metadata {
    name      = "git-deploy-key-${each.key}"
    namespace = each.value.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/component"  = "git-deploy-key"
    }
  }

  data = {
    "ssh-privatekey" = each.value.ssh_privatekey
    "known_hosts" = lookup(
      local._known_hosts,
      each.value.host,
      "${each.value.host} ssh-rsa <unknown — add this host to local._known_hosts in git_deploy_keys.tf>"
    )
  }

  type = "kubernetes.io/ssh-auth"
}
