# Known bugs / follow-ups — terraform-minikube-platform

## 1. Destroy-time CF tunnel force-delete swallows its output

`cloudflare.tf` — `null_resource.cloudflare_tunnel_force_delete` keeps the
Cloudflare API token inside `triggers` (so the destroy-time `local-exec`
can reference it via `self.triggers.api_token`, which is the only way to
pass a value into a destroy-time provisioner under Terraform ≥ 0.13).
`var.cloudflare_api_token` is declared `sensitive = true`, and the flag
**propagates to the whole `triggers` map and every block that reads it** —
so Terraform suppresses the provisioner's stdout:

```
null_resource.cloudflare_tunnel_force_delete (local-exec):
  (output suppressed due to sensitive value in config)
```

Correct security behaviour (prevents the token from landing in plaintext
TF logs), but makes the destroy step opaque — operator can't tell whether
the tunnel actually got force-deleted or the curl 30s-timeout fired.

**Proposed fix:** drop the token out of `triggers` and read it from the
shell environment inside the destroy script — the `./tf` wrapper already
exports `$TF_VAR_cloudflare_api_token` / `$CLOUDFLARE_API_TOKEN` for every
subcommand. The `local-exec` environment block only needs `ACCOUNT_ID` and
`TUNNEL_ID` (both non-sensitive) from `self.triggers`; the script inside
reads `$TF_VAR_cloudflare_api_token` directly. No sensitivity propagates,
stdout gets logged normally.

Rough shape:
```hcl
triggers = {
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id
  account_id = var.cloudflare_account_id
}
provisioner "local-exec" {
  when        = destroy
  on_failure  = continue
  interpreter = ["bash", "-c"]
  environment = {
    ACCOUNT_ID = self.triggers.account_id
    TUNNEL_ID  = self.triggers.tunnel_id
  }
  command = <<-EOT
    set -euo pipefail
    : "${TF_VAR_cloudflare_api_token:?CF token missing — must be exported by ./tf wrapper}"
    curl -fsS --max-time 30 -X DELETE \
      -H "Authorization: Bearer $TF_VAR_cloudflare_api_token" \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID?force=true" \
      > /dev/null
  EOT
}
```

Verify by running `terraform destroy` with `TF_LOG=INFO` — should see the
curl's exit status streaming through instead of being suppressed.

## 2. `variable "pod_cidr"` is declared but never read

`variables.tf:19-28` declares `variable "pod_cidr"` with default
`10.244.0.0/16` and a comment claiming "minikube's Flannel addon
hardcodes `10.244.0.0/16` in its kube-flannel-cfg ConfigMap and ignores
kubeadm.pod-network-cidr". Neither the default nor the comment reflects
the active cluster any more:

- **Not wired.** `main.tf:32-41` (Option A, the active minikube block)
  does not pass `pod_cidr = var.pod_cidr` to `module "k8s"`, and no
  `resource` / `local` / `output` reads it either. `grep -n var.pod_cidr
  *.tf` returns only the declaration line. Whatever the operator sets
  (via `TF_VAR_pod_cidr`, tfvars, or default) never reaches the cluster.
- **Stale comment.** The cluster module (`terraform-minikube-k8s`
  v3.1.0+) disables the built-in Flannel addon (`cni = "false"`) and
  applies its own manifest with `replace(..., "10.244.0.0/16",
  var.pod_cidr)`. The "addon hardcodes 10.244" story is historical.
- **Actual cluster CIDR.** Comes from the child module's
  `var.pod_cidr` default — currently `100.72.0.0/16` — paired with
  `service_cidr` default `100.64.0.0/20`. Disjoint, CGNAT, avoids the
  kicbase podman-bridge collision on `10.244.0.1`.

**Proposed fix — pick one:**

- **A.** Delete the variable. Nothing in this repo consumes it; removing
  the dead surface is cleaner than maintaining an illusion of control.
- **B.** Wire it through: change default to `100.72.0.0/16`, rewrite the
  comment to cite the podman-bridge collision (not addon hardcoding),
  add `pod_cidr = var.pod_cidr` to the `module "k8s"` block in
  `main.tf`. Preserves an operator-facing override knob.

Either way, `docs/architecture.md:205-206` also needs a pass — it
still claims `pod_cidr` is "hardcoded on minikube" and service CIDR is
`100.64.0.0/12`, both wrong post-v3.1.0.
