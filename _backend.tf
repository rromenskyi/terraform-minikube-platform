# Terraform state backend.
#
# This file deliberately holds NO operator-specific values. Bucket
# name, endpoint, region, and state object key all come from `.env`
# (gitignored) via `-backend-config` flags injected by `./tf init`.
# That keeps the repo public-safe — only the s3-on-B2 quirks
# (`skip_*` / `use_path_style`) are committed because they're
# identical across every operator running this stack on B2.
#
# Migration steps (gentle, lossless):
#   1. Confirm `.env` has AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
#      AWS_REGION / B2_BUCKET / B2_ENDPOINT (see `.env.example`)
#   2. `./tf init -migrate-state`
#      - terraform reads existing local `terraform.tfstate`, copies
#        the contents to B2 under `<state_key>`, prompts to confirm
#   3. After confirmation B2 holds the live state; the local file
#      stays as a one-shot backup but is no longer authoritative
#   4. Optional cleanup: `mv terraform.tfstate terraform.tfstate.preremote`
#      so future commands clearly fail if anything regresses
#
# Rollback to local is symmetric — flip the backend block back to
# `local` and `./tf init -migrate-state` pulls the state down.
#
# B2 bucket-level versioning ("snapshots") gives free rollback — a
# bad apply stays on the bucket as a previous version. Enable in B2
# console once; operator owns that knob, not Terraform.

terraform {
  backend "s3" {
    # B2 quirks — committed because they're identical across every
    # operator running this stack on B2. Without these the AWS
    # provider tries to validate against AWS endpoints / signatures /
    # account IDs and rejects every B2 request.
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
