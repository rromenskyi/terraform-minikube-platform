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
