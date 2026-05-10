# `git_deploy_keys` migrated to per-tenant Vault mode in
# `modules/project`: domain yaml declares
# `git_deploy_keys: { <id>: { host: github.com } }` per env, engine
# emits a `VaultStaticSecret` pointing at
# `secret/data/tenants/<slug>/git-deploy-keys/<id>`, VSO syncs into a
# `kubernetes.io/ssh-auth` Secret with the static `known_hosts` line
# combined in via VSO templating. Tenant uploads the private key to
# Vault themselves via Zitadel SSO.
#
# This file used to declare a flat `var.git_deploy_keys` map taking
# private keys verbatim from `terraform.tfvars`. That shape is gone.
# File kept as a sentinel comment — drop entirely once the engine
# refactor has aged and no consumer doc references the old path.
