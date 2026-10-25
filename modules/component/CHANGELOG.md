# Changelog

All notable changes to this module are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project itself follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- `volume_preferred_node_selectors`: with volumes on `storage_class`, a soft preference (weight 100, one term per selector) for the nodes holding the volume's copies, added to the caller's own preferred node terms.

### Added
- `env_from_secrets`: existing Secrets mounted whole as env (`envFrom`).
- `image_pull_secrets`: the pod's `imagePullSecrets`, for components under
  their own ServiceAccount, which does not inherit the default one's.
- `storage_class` / `storage_seed_node`: `storage` volumes on a StorageClass
  (dynamic PVC `data-<component>-<slug>`, app data in its `data/`, Deployment
  strategy Recreate), with a one-time copy of the old hostPath directories
  on the first start (modules/volume-seed).
- `storage_node`: pins the pod to the node holding its hostPath volumes
  and gives new PVs a matching nodeAffinity (existing PVs keep theirs;
  `ignore_changes` avoids replacing a bound PV). Without it a pod that
  moved nodes ran on that node's stale copy and writes diverged.

### Added
- **GCP Workload Identity Federation knobs (`gcp_wif_credential_configmap_name`
  / `gcp_wif_audience`).** When the caller passes a non-null ConfigMap
  name, the deployment pod gets: a dedicated ServiceAccount (so the
  GCP-side `principalSet://...subject/system:serviceaccount:<ns>:<sa>`
  binding resolves to ONLY this component, not the namespace's shared
  `default` SA); a projected `serviceAccountToken` volume at
  `/var/run/secrets/gcp/tokens/token` with the caller-supplied audience;
  a ConfigMap mount at `/var/run/secrets/gcp/creds` carrying
  `credential-config.json`; and `GOOGLE_APPLICATION_CREDENTIALS` env
  var pointing at that file. GCP SDKs auto-detect the external-account
  flow and impersonate the GCP SA without any static credential.
  Defaults are null/empty — existing components are unaffected.
  ServiceAccount creation gate (`local.sa_instances`) now fires on
  either `cluster_role_rules` non-empty OR WIF opt-in.

### Changed
- File layout split into `main.tf` / `variables.tf` / `outputs.tf` per AGENT.md
  module conventions. Pure file reorganisation — no resource, input, output, or
  default value changed; `terraform plan` is identical before and after.
- Initial `README.md` and `CHANGELOG.md` added per AGENT.md module conventions.
