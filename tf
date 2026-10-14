#!/usr/bin/env bash
# Terraform wrapper that loads .env and offers a few composable subcommands.
#
# Pass-through — delegates straight to `terraform`:
#   ./tf plan
#   ./tf apply
#   ./tf destroy
#   ./tf init
#   ./tf <anything else>
#
#   On an S3-compatible backend without native locking (e.g. Backblaze B2),
#   plan/apply/destroy/import/refresh/taint/untaint and state mv/rm/push
#   take the wrapper's state lock first (see "State lock" below).
#   `--no-lock` skips it.
#
#   ./tf lock-status   who holds the wrapper's state lock, if anyone
#   ./tf unlock        remove a stuck wrapper lock (after checking the holder is gone)
#
# Two stacks: the repository root is the platform (everything inside the
# cluster); `cluster/` brings the cluster itself up over SSH / minikube and
# writes the kubeconfig the platform reads. The pass-through above runs the
# platform stack; the cluster stack runs through:
#   ./tf cluster <terraform args>    e.g. ./tf cluster init, ./tf cluster plan
#   ./tf cluster lock-status | unlock
#   Its state is separate (local by default, or its own key next to the
#   platform's), and so is its wrapper lock. The bootstrap-* flows hold only
#   the platform's lock while they also drive the cluster stack.
#
# Subcommands with extra orchestration:
#   ./tf cloudflare-purge
#     Deletes the platform Cloudflare tunnel + any DNS CNAMEs that still point
#     at *.cfargotunnel.com. Useful when Terraform state was wiped mid-apply
#     and the tunnel or DNS records were orphaned on the Cloudflare side.
#
#   ./tf bootstrap-minikube [-y|--yes]
#     Full-reset flow for the minikube distribution (Option A in cluster/main.tf):
#     resets the local minikube profile, wipes local Terraform state, runs a
#     phased apply (cluster first, then MySQL, then the rest) with
#     Flannel/CNI cleanup between phases. Host volume data is NOT deleted —
#     it survives. Cloudflare tunnel / DNS are NOT touched by this command —
#     if an existing tunnel with the same name is found in the operator's
#     account, bootstrap aborts with a pointer to `./tf cloudflare-purge`
#     (nuke) or `terraform import` (adopt).
#
#   ./tf bootstrap-k3s [-y|--yes]
#     Full-reset flow for the k3s distribution (Option B in cluster/main.tf):
#     `terraform destroy` of the platform (tears down the tunnel), then of the
#     cluster stack (SSH uninstall of k3s), force-uninstalls k3s over SSH in
#     case the destroy-time provisioner was skipped, wipes local Terraform
#     state of both stacks, then applies the cluster stack and the platform.
#     Host volume data under `$HOST_VOLUME_PATH` is NOT deleted.
#     Cloudflare-side behaviour same as bootstrap-minikube: preflight fails
#     if a named tunnel already exists; operator decides purge vs import.
#
# Both `bootstrap-*` subcommands stop on an interactive confirmation prompt
# BEFORE running anything destructive. The prompt lists exactly what will be
# destroyed and what will be preserved, so the operator sees the blast
# radius before the first `rm -rf`. Skip the prompt in CI / scripted flows
# with `BOOTSTRAP_YES=1` in the environment or `-y` / `--yes` on the
# command line.
#
# CF tunnel purge is a DELIBERATELY separate subcommand (`./tf cloudflare-purge`)
# — it was invoked automatically by bootstrap historically, but a single
# shared Cloudflare account between a prod cluster and a test clone with the
# same tunnel name means one accidental bootstrap can delete prod's tunnel +
# every DNS CNAME routed through it. Making purge explicit stops that class
# of incident.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Warning: $ENV_FILE not found" >&2
else
  echo "Loading variables from .env..." >&2
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      value="${value#\"}"
      value="${value%\"}"
      value="${value#\'}"
      value="${value%\'}"
      # Two accepted key styles in .env:
      #   FOO_BAR=...        (plain)     → exported under TWO names:
      #                                       FOO_BAR=... (native, original case)
      #                                       TF_VAR_foo_bar=...
      #   TF_VAR_foo_bar=... (pre-fixed) → exported as TF_VAR_foo_bar
      #                                    (only — there is no native form
      #                                    for a TF-input-only key)
      #
      # Why both forms for plain keys: provider SDKs (Cloudflare, AWS S3
      # backend, kubectl, GCP, etc.) read native env-var names directly
      # — `CLOUDFLARE_API_TOKEN`, `AWS_ACCESS_KEY_ID` — and do NOT
      # understand `TF_VAR_*`. The S3 backend block in particular is
      # parsed BEFORE Terraform evaluates `var.*`, so a backend
      # configured to read credentials cannot reference an input
      # variable; it has to find the SDK env vars under their native
      # names. Meanwhile, modules that thread a value through a
      # `variable "foo" {}` block need `TF_VAR_foo`. Exporting both
      # lets the operator's TF code use whichever path is appropriate
      # without rewriting `.env` per consumer.
      #
      # Why the pre-fixed branch exists at all: without it, a key like
      # `TF_VAR_ssh_host` in `.env` would double up as
      # `TF_VAR_tf_var_ssh_host` and silently not reach Terraform.
      # `.env.example` uses the pre-fixed style for the k3s SSH knobs
      # because that is the idiomatic Terraform env-var form for inputs
      # that have no SDK consumer.
      lower_key="$(echo "$key" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_key" == tf_var_* ]]; then
        tf_var_name="TF_VAR_${lower_key#tf_var_}"
        export "$tf_var_name"="$value"
        echo "  $tf_var_name=*** (hidden)" >&2
      else
        export "$key"="$value"
        tf_var_name="TF_VAR_${lower_key}"
        export "$tf_var_name"="$value"
        echo "  $key=*** (hidden)" >&2
        echo "  $tf_var_name=*** (hidden)" >&2
      fi
    fi
  done < "$ENV_FILE"
fi

resolve_cluster_name() {
  if [[ -n "${TF_VAR_cluster_name:-}" ]]; then
    printf '%s\n' "${TF_VAR_cluster_name}"
    return
  fi

  local tfvars_file=""
  local parsed=""

  shopt -s nullglob
  for tfvars_file in "${SCRIPT_DIR}/terraform.tfvars" "${SCRIPT_DIR}"/*.auto.tfvars; do
    [[ -f "${tfvars_file}" ]] || continue
    parsed="$(sed -nE 's/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p' "${tfvars_file}" | head -n 1)"
    if [[ -n "${parsed}" ]]; then
      shopt -u nullglob
      printf '%s\n' "${parsed}"
      return
    fi
  done
  shopt -u nullglob

  printf '%s\n' "minikube"
}

resolve_cloudflare_tunnel_name() {
  printf '%s\n' "platform"
}

# ── Zitadel port-forward (provider transport) ────────────────────────────────
#
# The Zitadel TF provider speaks gRPC. Cloudflare's pure-proxy mode
# strips HTTP/2 trailers on the response, which the provider's grpc-go
# client treats as an unrecoverable stream-closed error. Bypass the
# CF chain entirely by pointing the provider at a kubectl port-forward
# tunnel; provider config in zitadel.tf reads `domain=localhost`,
# `port=8080`, `transport_headers.Host=<external_domain>` to keep
# Zitadel's instance routing happy.
#
# Skip cleanly when Zitadel isn't deployed yet — first apply on a
# clean cluster has no zitadel Service to forward to, and we don't
# want bootstrap to break on its absence.
ZITADEL_PF_PID=""

# kubectl talks to the same cluster as the Terraform providers: the platform
# stack's TF_VAR_kubeconfig_path / TF_VAR_kube_context when set (CI), else
# kubectl's own default.
KUBECTL_ARGS=()
[[ -n "${TF_VAR_kubeconfig_path:-}" ]] && KUBECTL_ARGS+=(--kubeconfig "${TF_VAR_kubeconfig_path}")
[[ -n "${TF_VAR_kube_context:-}" ]] && KUBECTL_ARGS+=(--context "${TF_VAR_kube_context}")

# Read the operator-supplied transport mode from config/platform.yaml.
# Default (when the file is missing or the key is unset) is the
# port-forward path so a clean clone with Cloudflare in the chain
# bootstraps without operator intervention. Site-specific overrides
# in `services.zitadel.provider.mode` flip this off.
zitadel_provider_mode() {
  local cfg="${SCRIPT_DIR}/config/platform.yaml"
  [[ -f "${cfg}" ]] || { printf '%s\n' "port_forward"; return; }
  local mode
  mode="$(awk '
    /^[[:space:]]*zitadel:/   { in_z=1; next }
    in_z && /^[[:space:]]*provider:/ { in_p=1; next }
    in_p && /^[[:space:]]*mode:/ {
      sub(/.*mode:[[:space:]]*/, "")
      gsub(/["[:space:]]/, "")
      print; exit
    }
    /^[a-zA-Z]/ { in_z=0; in_p=0 }
  ' "${cfg}" 2>/dev/null)"
  printf '%s\n' "${mode:-port_forward}"
}

start_zitadel_port_forward() {
  local mode
  mode="$(zitadel_provider_mode)"
  if [[ "${mode}" != "port_forward" ]]; then
    return 0
  fi
  if ! kubectl "${KUBECTL_ARGS[@]+"${KUBECTL_ARGS[@]}"}" get svc zitadel -n platform >/dev/null 2>&1; then
    return 0
  fi
  # Only a listener the provider can reach on 127.0.0.1 counts: services
  # bound to a specific other address (e.g. NodeLocal DNSCache's health
  # check on 169.254.20.10:8080) do not.
  if ss -tln 2>/dev/null | grep -qE '(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]):8080 '; then
    echo "tf: localhost:8080 already in use — skipping kubectl port-forward (assumed already running)" >&2
    return 0
  fi
  echo "tf: kubectl port-forward svc/zitadel 8080:8080 (provider transport, bypasses Cloudflare gRPC trailer-strip)" >&2
  kubectl "${KUBECTL_ARGS[@]+"${KUBECTL_ARGS[@]}"}" port-forward -n platform svc/zitadel 8080:8080 >/dev/null 2>&1 &
  ZITADEL_PF_PID=$!
  # Probe the local TCP listener only — that's all the wrapper has to wait for.
  # Whether Zitadel itself is ready behind the listener is the provider's
  # concern (it'll error cleanly if not). Earlier versions waited on
  # `/.well-known/openid-configuration` and false-warned on cold-start
  # Zitadel; bash's `<>` open against the listener probes only the
  # kubectl-side TCP, completes in <1s on a warm pod.
  for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
      exec 3<&- 3>&-
      return 0
    fi
    sleep 0.25
  done
  echo "tf: port-forward never became ready, continuing anyway (Zitadel may not be up yet)" >&2
}

stop_zitadel_port_forward() {
  if [[ -n "${ZITADEL_PF_PID:-}" ]]; then
    kill "${ZITADEL_PF_PID}" 2>/dev/null || true
    wait "${ZITADEL_PF_PID}" 2>/dev/null || true
    ZITADEL_PF_PID=""
  fi
}

# ── State lock for S3-compatible backends without native locking ─────────
#
# Terraform's S3 backend locks only with `use_lockfile` (conditional writes)
# or a DynamoDB table. Some S3-compatible stores have neither: Backblaze B2
# answers a conditional PUT with 501 NotImplemented. Two runs (an operator
# and CI) could then write the state at the same time. For such a backend
# the wrapper keeps its own lock object next to the state
# (`<key>.wrapper-lock`):
#
#   - acquire: a lock renewed within STATE_LOCK_STALE_SECONDS belongs to
#     someone else, so refuse. Otherwise write ours, wait, read it back and
#     own it only if it is still ours. The store has no atomic
#     create-if-absent, so this narrows the two-writers window to runs that
#     start within the same few seconds;
#   - renewed every STATE_LOCK_RENEW_SECONDS while Terraform runs;
#   - removed on exit, success or not, if it is still ours.
#
# The lock lives where the state lives, so it works while the cluster is
# down. `--no-lock` (or TF_WRAPPER_NO_LOCK=1) skips it; `./tf lock-status`
# shows the holder and `./tf unlock` removes a stuck lock.
# TF_WRAPPER_LOCK_HOLDER names the holder (CI sets its run). Backends with
# native locking (`use_lockfile`, `dynamodb_table`), plain AWS S3 and
# non-S3 backends are left to Terraform.

STATE_LOCK_STALE_SECONDS="${TF_WRAPPER_LOCK_STALE_SECONDS:-3600}"
STATE_LOCK_RENEW_SECONDS="${TF_WRAPPER_LOCK_RENEW_SECONDS:-300}"
STATE_LOCK_SETTLE_SECONDS=5
STATE_LOCK_URL=""
# The stack whose state is locked: the platform (repository root) by default,
# `cluster/` for `./tf cluster ...`. Each has its own state, so its own lock.
STATE_LOCK_STACK_DIR="${SCRIPT_DIR}"
# How the operator names this stack on the command line, for hints.
STATE_LOCK_CMD="./tf"
STATE_LOCK_REGION=""
STATE_LOCK_ID=""
STATE_LOCK_RENEW_PID=""

# Sets STATE_LOCK_URL / STATE_LOCK_REGION. Returns 0 when the wrapper lock
# applies, 1 when it does not (native locking, plain AWS, non-S3 backend),
# 2 when the backend cannot be determined (not initialised, jq missing).
state_lock_backend() {
  local backend="${STATE_LOCK_STACK_DIR}/.terraform/terraform.tfstate"
  [[ -f "${backend}" ]] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  [[ "$(jq -r '.backend.type // empty' "${backend}")" == "s3" ]] || return 1
  [[ "$(jq -r '(.backend.config.use_lockfile // false) or ((.backend.config.dynamodb_table // "") != "")' "${backend}")" == "false" ]] || return 1
  local bucket key endpoint region
  bucket="$(jq -r '.backend.config.bucket // empty' "${backend}")"
  key="$(jq -r '.backend.config.key // empty' "${backend}")"
  endpoint="$(jq -r '.backend.config.endpoints.s3 // .backend.config.endpoint // empty' "${backend}")"
  [[ -n "${bucket}" && -n "${key}" && -n "${endpoint}" ]] || return 1
  region="$(jq -r '.backend.config.region // "us-east-1"' "${backend}")"
  # S3-compatible stores name their region in the endpoint host
  # (`s3.<region>.<domain>`) and expect signatures for it.
  if [[ "${endpoint}" =~ ://s3\.([a-z0-9-]+)\. ]]; then
    region="${BASH_REMATCH[1]}"
  fi
  STATE_LOCK_URL="${endpoint%/}/${bucket}/${key}.wrapper-lock"
  STATE_LOCK_REGION="${TF_WRAPPER_LOCK_REGION:-${region}}"
}

# state_lock_s3 <METHOD> <body-out-file> [curl args...]; prints the HTTP code.
# Credentials go through a curl config on a file descriptor, not argv.
state_lock_s3() {
  local method="$1" out="$2"
  shift 2
  curl -sS -o "${out}" -w '%{http_code}' --max-time 30 \
    -K <(printf 'user = "%s:%s"\n' "${AWS_ACCESS_KEY_ID:-}" "${AWS_SECRET_ACCESS_KEY:-}") \
    --aws-sigv4 "aws:amz:${STATE_LOCK_REGION}:s3" \
    -H 'x-amz-content-sha256: UNSIGNED-PAYLOAD' \
    -X "${method}" "$@" "${STATE_LOCK_URL}" || true
}

# Reads the lock into STATE_LOCK_SEEN_* ; returns 0 locked, 1 free, 2 error.
read_state_lock() {
  local tmp code
  tmp="$(mktemp)"
  code="$(state_lock_s3 GET "${tmp}")"
  STATE_LOCK_SEEN_HOLDER="$(sed -n 's/^holder=//p' "${tmp}")"
  STATE_LOCK_SEEN_COMMAND="$(sed -n 's/^command=//p' "${tmp}")"
  STATE_LOCK_SEEN_SINCE="$(sed -n 's/^since=//p' "${tmp}")"
  STATE_LOCK_SEEN_RENEWED="$(sed -n 's/^renewed=//p' "${tmp}")"
  rm -f "${tmp}"
  case "${code}" in
    200) return 0 ;;
    404) return 1 ;;
    *) STATE_LOCK_SEEN_ERROR="HTTP ${code}"; return 2 ;;
  esac
}

write_state_lock() {
  local command="$1" since="$2" tmp code
  tmp="$(mktemp)"
  printf 'holder=%s\ncommand=%s\nsince=%s\nrenewed=%s\n' \
    "${STATE_LOCK_ID}" "${command}" "${since}" "$(date +%s)" > "${tmp}"
  code="$(state_lock_s3 PUT /dev/null --data-binary "@${tmp}")"
  rm -f "${tmp}"
  [[ "${code}" == "200" ]]
}

describe_seen_lock() {
  local now
  now="$(date +%s)"
  printf '%s (%s, since %s, renewed %ss ago)' \
    "${STATE_LOCK_SEEN_HOLDER:-?}" "${STATE_LOCK_SEEN_COMMAND:-?}" \
    "$(date -d "@${STATE_LOCK_SEEN_SINCE:-0}" '+%F %T %Z' 2>/dev/null || echo '?')" \
    "$(( now - ${STATE_LOCK_SEEN_RENEWED:-0} ))"
}

acquire_state_lock() {
  local command="$1" rc=0 now age
  read_state_lock || rc=$?
  if [[ "${rc}" == "2" ]]; then
    echo "tf: cannot read the state lock (${STATE_LOCK_SEEN_ERROR}). Rerun with --no-lock only if you are sure nobody else is running Terraform." >&2
    exit 1
  fi
  if [[ "${rc}" == "0" ]]; then
    now="$(date +%s)"
    age=$(( now - ${STATE_LOCK_SEEN_RENEWED:-0} ))
    if (( age < STATE_LOCK_STALE_SECONDS )); then
      echo "tf: the state is locked by $(describe_seen_lock)." >&2
      echo "tf: wait for it, or run '${STATE_LOCK_CMD} unlock' if you are sure that run is gone." >&2
      exit 1
    fi
    echo "tf: taking over a stale state lock: $(describe_seen_lock)." >&2
  fi

  STATE_LOCK_ID="${TF_WRAPPER_LOCK_HOLDER:-$(id -un)@$(hostname)}/$$-${RANDOM}"
  if ! write_state_lock "${command}" "$(date +%s)"; then
    STATE_LOCK_ID=""
    echo "tf: cannot write the state lock." >&2
    exit 1
  fi
  # No atomic create-if-absent: let a concurrent writer land, then check
  # whose lock survived.
  sleep "${STATE_LOCK_SETTLE_SECONDS}"
  rc=0
  read_state_lock || rc=$?
  if [[ "${rc}" != "0" || "${STATE_LOCK_SEEN_HOLDER}" != "${STATE_LOCK_ID}" ]]; then
    STATE_LOCK_ID=""
    echo "tf: lost the state lock to $(describe_seen_lock); not running." >&2
    exit 1
  fi
  echo "tf: state lock held by ${STATE_LOCK_ID}" >&2

  local since="${STATE_LOCK_SEEN_SINCE}" id="${STATE_LOCK_ID}" wrapper_pid="$$"
  # The renew loop sleeps in a child it can kill: a plain `sleep` left
  # behind after the loop is stopped keeps the wrapper's stdout open, and a
  # pipe reading it (`./tf plan | tee`, CI) would hang until it ends.
  (
    set +e
    sleeper=""
    trap '[[ -n "${sleeper}" ]] && kill "${sleeper}" 2>/dev/null; exit 0' TERM
    while :; do
      sleep "${STATE_LOCK_RENEW_SECONDS}" &
      sleeper=$!
      wait "${sleeper}"
      sleeper=""
      if read_state_lock && [[ "${STATE_LOCK_SEEN_HOLDER}" == "${id}" ]]; then
        STATE_LOCK_ID="${id}" write_state_lock "${command}" "${since}" \
          || echo "tf: failed to renew the state lock" >&2
      else
        # Someone took the lock over (we did not renew for a stale period,
        # or it was removed with `unlock`). Two writers must not continue:
        # stop Terraform the way Ctrl-C does, once.
        echo "tf: ERROR: the state lock is no longer ours (now: $(describe_seen_lock)); stopping Terraform." >&2
        pkill -INT -P "${wrapper_pid}" -x terraform 2>/dev/null || true
        exit 0
      fi
    done
  ) &
  STATE_LOCK_RENEW_PID=$!
}

release_state_lock() {
  if [[ -n "${STATE_LOCK_RENEW_PID}" ]]; then
    kill "${STATE_LOCK_RENEW_PID}" 2>/dev/null || true
    wait "${STATE_LOCK_RENEW_PID}" 2>/dev/null || true
    STATE_LOCK_RENEW_PID=""
  fi
  [[ -n "${STATE_LOCK_ID}" ]] || return 0
  if read_state_lock && [[ "${STATE_LOCK_SEEN_HOLDER}" == "${STATE_LOCK_ID}" ]]; then
    state_lock_s3 DELETE /dev/null >/dev/null
    echo "tf: state lock released" >&2
  fi
  STATE_LOCK_ID=""
}

# Commands that read the state to change it (or plan against it) take the
# lock. `-chdir=...` style global flags before the command are skipped.
state_lock_needed() {
  local arg sub="" in_state=0
  for arg in "$@"; do
    [[ "${arg}" == -* ]] && continue
    if [[ "${in_state}" == "1" ]]; then
      case "${arg}" in mv|rm|push|replace-provider) return 0 ;; esac
      return 1
    fi
    if [[ -z "${sub}" ]]; then
      sub="${arg}"
      case "${sub}" in
        plan|apply|destroy|import|refresh|taint|untaint) return 0 ;;
        state) in_state=1 ;;
        *) return 1 ;;
      esac
    fi
  done
  return 1
}

lock_state_for() {
  if [[ "${TF_WRAPPER_NO_LOCK:-}" == "1" ]]; then
    echo "tf: state lock skipped (--no-lock)" >&2
    return 0
  fi
  local rc=0
  state_lock_backend || rc=$?
  case "${rc}" in
    0) acquire_state_lock "$1" ;;
    1) return 0 ;;
    *)
      # Fail closed: an unknown backend must not mean "unlocked".
      echo "tf: cannot determine the backend (.terraform/terraform.tfstate missing or jq not installed); run '${STATE_LOCK_CMD} init' first, or --no-lock if you are sure nobody else is running." >&2
      exit 1
      ;;
  esac
}

cleanup() {
  release_state_lock
  stop_zitadel_port_forward
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# `--no-lock` belongs to the wrapper, not to Terraform.
ARGS=()
for arg in "$@"; do
  if [[ "${arg}" == "--no-lock" ]]; then
    TF_WRAPPER_NO_LOCK=1
  else
    ARGS+=("${arg}")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

reset_minikube_profile() {
  local profile="$1"
  local profile_dir="${HOME}/.minikube/profiles/${profile}"
  local machine_dir="${HOME}/.minikube/machines/${profile}"

  echo "Step 0: Resetting local minikube profile metadata for ${profile}..."
  minikube delete -p "${profile}" >/dev/null 2>&1 || true
  rm -rf "${profile_dir}" "${machine_dir}"
}

reset_terraform_state() {
  local state_path="${SCRIPT_DIR}/terraform.tfstate"
  local backup_path="${SCRIPT_DIR}/terraform.tfstate.backup"
  local lock_path="${SCRIPT_DIR}/.terraform.tfstate.lock.info"

  echo "Step 0.25: Resetting local Terraform state..."
  rm -f "${state_path}" "${backup_path}" "${lock_path}" \
    "${SCRIPT_DIR}/cluster/terraform.tfstate" \
    "${SCRIPT_DIR}/cluster/terraform.tfstate.backup" \
    "${SCRIPT_DIR}/cluster/.terraform.tfstate.lock.info"
}

# `./tf lock-status` / `./tf cluster lock-status`: who holds the stack's lock.
show_state_lock() {
  local rc=0
  state_lock_backend || rc=$?
  case "${rc}" in
    0) ;;
    1) echo "tf: the wrapper lock does not apply to this backend (native locking or non-S3)."; exit 0 ;;
    *) echo "tf: cannot determine the backend; run '${STATE_LOCK_CMD} init' first." >&2; exit 1 ;;
  esac
  rc=0
  read_state_lock || rc=$?
  case "${rc}" in
    0) echo "locked by $(describe_seen_lock)" ;;
    1) echo "unlocked" ;;
    *) echo "cannot read the lock (${STATE_LOCK_SEEN_ERROR})" >&2; exit 1 ;;
  esac
}

# `./tf unlock` / `./tf cluster unlock`: remove a stuck lock of the stack.
remove_state_lock() {
  local rc=0 code
  state_lock_backend || rc=$?
  case "${rc}" in
    0) ;;
    1) echo "tf: no wrapper lock for this backend."; exit 0 ;;
    *) echo "tf: cannot determine the backend; run '${STATE_LOCK_CMD} init' first." >&2; exit 1 ;;
  esac
  rc=0
  read_state_lock || rc=$?
  case "${rc}" in
    1) echo "unlocked"; exit 0 ;;
    2) echo "tf: cannot read the state lock (${STATE_LOCK_SEEN_ERROR}); not removing anything." >&2; exit 1 ;;
  esac
  echo "removing the state lock held by $(describe_seen_lock)"
  code="$(state_lock_s3 DELETE /dev/null)"
  if [[ "${code}" != "204" && "${code}" != "200" ]]; then
    echo "tf: removing the lock failed (HTTP ${code})." >&2
    exit 1
  fi
  rc=0
  read_state_lock || rc=$?
  [[ "${rc}" == "1" ]] || { echo "tf: the lock is still there after removal." >&2; exit 1; }
  echo "unlocked"
}

# The cluster stack (`cluster/`): k3s over SSH or minikube. Initialised on
# first use, unless the command is `init` itself (with its own arguments).
cluster_terraform() {
  if [[ "${1:-}" != "init" && ! -d "${SCRIPT_DIR}/cluster/.terraform" ]]; then
    terraform -chdir="${SCRIPT_DIR}/cluster" init -input=false
  fi
  terraform -chdir="${SCRIPT_DIR}/cluster" "$@"
}

purge_cloudflare_tunnel() {
  # Deletes (a) every Cloudflare tunnel matching $tunnel_name and (b) every
  # DNS CNAME that points at *that specific tunnel's* cfargotunnel hostname.
  #
  # Why scope DNS deletion by tunnel UUID rather than "any *.cfargotunnel.com":
  # the operator's Cloudflare account typically has OTHER tunnels unrelated to
  # this platform — an SSH proxy into the workstation, side projects, a home
  # lab — and their CNAMEs also end in ".cfargotunnel.com". A blanket
  # endswith("cfargotunnel.com") filter will happily delete those too, taking
  # down remote access. Always filter DNS cleanup by `endswith(<tunnel_id>.cfargotunnel.com)`.
  local tunnel_name="$1"
  local api_token="${TF_VAR_cloudflare_api_token:-}"
  local account_id="${TF_VAR_cloudflare_account_id:-}"
  local api_url=""
  local response=""
  local tunnel_ids=""
  local tunnel_id=""

  if [[ -z "${api_token}" || -z "${account_id}" ]]; then
    echo "Step 0.5: Skipping Cloudflare tunnel purge (${tunnel_name}) because Cloudflare credentials are not loaded."
    return
  fi

  echo "Step 0.5: Purging stale Cloudflare tunnel ${tunnel_name}..."
  api_url="https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel"
  response="$(curl -fsS \
    -H "Authorization: Bearer ${api_token}" \
    -H "Content-Type: application/json" \
    "${api_url}")"

  tunnel_ids="$(printf '%s' "${response}" | jq -r --arg NAME "${tunnel_name}" '.result[]? | select(.name == $NAME) | .id')"

  if [[ -z "${tunnel_ids}" ]]; then
    echo "  No existing Cloudflare tunnel named ${tunnel_name} found."
    return
  fi

  while IFS= read -r tunnel_id; do
    [[ -n "${tunnel_id}" ]] || continue

    # Scope DNS cleanup to this tunnel's target hostname before the tunnel
    # itself is deleted — once deleted, we can no longer map UUID→name.
    purge_dns_records_for_tunnel "${tunnel_id}" "${tunnel_name}"

    echo "  Removing tunnel connections for ${tunnel_name} (${tunnel_id})..."
    curl -fsS -X DELETE \
      -H "Authorization: Bearer ${api_token}" \
      -H "Content-Type: application/json" \
      "${api_url}/${tunnel_id}/connections" >/dev/null

    echo "  Deleting Cloudflare tunnel ${tunnel_name} (${tunnel_id})..."
    curl -fsS -X DELETE \
      -H "Authorization: Bearer ${api_token}" \
      -H "Content-Type: application/json" \
      "${api_url}/${tunnel_id}" >/dev/null
  done <<< "${tunnel_ids}"
}

purge_dns_records_for_tunnel() {
  # Delete every CNAME across every zone whose content is
  # `<tunnel_id>.cfargotunnel.com` — i.e., only hostnames routed to THIS
  # tunnel. CNAMEs that point at other tunnels (SSH proxy, unrelated
  # projects) are untouched. See the warning in purge_cloudflare_tunnel.
  local tunnel_id="$1"
  local tunnel_name="$2"
  local api_token="${TF_VAR_cloudflare_api_token:-}"
  local cname_target="${tunnel_id}.cfargotunnel.com"

  if [[ -z "${api_token}" ]]; then
    echo "  Skipping DNS cleanup for tunnel ${tunnel_name} (no Cloudflare token)."
    return
  fi

  local zone_ids
  zone_ids="$(curl -fsS \
    -H "Authorization: Bearer ${api_token}" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    | jq -r '.result[]?.id')"

  if [[ -z "${zone_ids}" ]]; then
    echo "  No Cloudflare zones visible to this token — skipping DNS cleanup for ${tunnel_name}."
    return
  fi

  echo "  Purging DNS CNAMEs that point at ${cname_target} (tunnel ${tunnel_name})..."
  local zone_id
  while IFS= read -r zone_id; do
    [[ -n "${zone_id}" ]] || continue
    local api_url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"

    local tunnel_records
    tunnel_records="$(curl -fsS \
      -H "Authorization: Bearer ${api_token}" \
      "${api_url}?type=CNAME&per_page=100" \
      | jq -r --arg TARGET "${cname_target}" '.result[]? | select(.content == $TARGET) | "\(.id) \(.name)"')"

    [[ -n "${tunnel_records}" ]] || continue

    local line rid name
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      rid="${line%% *}"
      name="${line#* }"
      echo "    Deleting CNAME '${name}' (${rid}) in zone ${zone_id}..."
      curl -fsS -X DELETE \
        -H "Authorization: Bearer ${api_token}" \
        "${api_url}/${rid}" >/dev/null
    done <<< "${tunnel_records}"
  done <<< "${zone_ids}"
}

preflight_no_existing_cf_tunnel() {
  # Abort bootstrap if a Cloudflare tunnel with the same name already
  # exists in the operator's account. Historical behaviour was to auto-purge
  # it as part of bootstrap — that is how a single accidental
  # `./tf bootstrap-*` run against a misconfigured clone can wipe a live
  # production tunnel + every DNS CNAME routed through it, which happened
  # in this session. Now bootstrap refuses to proceed; operator chooses
  # explicitly between destroying the tunnel (`./tf cloudflare-purge`) or
  # adopting it into state (`terraform import`).
  local tunnel_name="$1"
  local api_token="${TF_VAR_cloudflare_api_token:-}"
  local account_id="${TF_VAR_cloudflare_account_id:-}"

  if [[ -z "${api_token}" || -z "${account_id}" ]]; then
    echo "  Skipping CF tunnel preflight — credentials not loaded."
    return
  fi

  local response ids
  response="$(curl -fsS \
    -H "Authorization: Bearer ${api_token}" \
    "https://api.cloudflare.com/client/v4/accounts/${account_id}/cfd_tunnel?name=${tunnel_name}")"
  ids="$(printf '%s' "${response}" | jq -r '.result[]? | select(.deleted_at == null) | .id')"

  if [[ -n "${ids}" ]]; then
    cat >&2 <<EOF
Error: a Cloudflare tunnel named "${tunnel_name}" already exists in this
account (ID(s): ${ids}).

Bootstrap no longer wipes it automatically — a single accidental run used
to kill the prod tunnel when a test clone shared the same tunnel name in
the same account. Pick one path, then re-run bootstrap:

  1. Destroy the existing tunnel + its DNS CNAMEs (if the existing tunnel
     is an orphan / stale / the wrong one):

        ./tf cloudflare-purge

  2. Adopt the existing tunnel into Terraform state (if it is healthy and
     you want to keep routing through it):

        terraform import cloudflare_zero_trust_tunnel_cloudflared.main \\
          ${account_id}/<tunnel_id>
        # repeat for every cloudflare_record.tunnel[...] CNAME you want
        # adopted — see docs/cf-adopt.md for the full incantation.

EOF
    exit 1
  fi
}

preflight_config_files() {
  # Abort bootstrap before any destructive action if the per-operator
  # config files are missing. Both `config/platform.yaml` and every
  # `config/domains/*.yaml` are gitignored (they hold Cloudflare zone
  # IDs, service toggles, ollama model lists — per-cluster, per-operator
  # values). A fresh clone has `*.example` templates only. Without the
  # live files Terraform silently falls back to empty defaults:
  # `fileexists(...) ? yamldecode(...) : {}` in locals.tf disables every
  # shared service and `local.projects = {}` skips every tenant — the
  # cluster boots "successfully" with no databases and no routed
  # hostnames, which is confusing to debug.
  local missing=0
  if [[ ! -f "${SCRIPT_DIR}/config/platform.yaml" ]]; then
    cat >&2 <<EOF
Error: ${SCRIPT_DIR}/config/platform.yaml is missing.
  This file controls which shared services (mysql / postgres / redis /
  ollama) the platform layer brings up. Without it every service
  defaults to \`enabled: false\` and tenants relying on them get a
  cluster with no database.

  Fix:
    cp ${SCRIPT_DIR}/config/platform.yaml.example ${SCRIPT_DIR}/config/platform.yaml
    # then edit the file and flip the services you want on

EOF
    missing=1
  fi

  local domain_count=0
  if [[ -d "${SCRIPT_DIR}/config/domains" ]]; then
    shopt -s nullglob
    local f
    for f in "${SCRIPT_DIR}/config/domains"/*.yaml; do
      domain_count=$((domain_count + 1))
    done
    shopt -u nullglob
  fi
  if [[ "${domain_count}" -eq 0 ]]; then
    cat >&2 <<EOF
Error: ${SCRIPT_DIR}/config/domains/ contains no *.yaml tenant files.
  A bootstrap with zero domains produces a cluster where \`local.projects\`
  is empty and no tenant namespaces, deployments, IngressRoutes or
  Cloudflare CNAMEs are created. That is almost never what you want —
  the point of running bootstrap is to stand the cluster up FOR a set
  of tenants.

  Fix: create at least one tenant file, e.g.:
    cp ${SCRIPT_DIR}/config/domains/example.com.yaml.example \\
       ${SCRIPT_DIR}/config/domains/<your-domain>.yaml
    # then edit name / slug / cloudflare_zone_id / envs / routes

EOF
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

confirm_bootstrap_destructive() {
  # Interactive gate in front of every `bootstrap-*` subcommand. Consolidates
  # the destructive actions (profile delete, state wipe, Cloudflare tunnel
  # purge, SSH k3s uninstall) into one prompt so the operator sees ALL of
  # them laid out before any `rm -rf` runs. Skippable for CI via
  # `BOOTSTRAP_YES=1` or `-y` / `--yes` anywhere on the command line.
  local label="$1"
  local destroy_list="$2"
  local preserve_list="$3"
  shift 3

  local skip=${BOOTSTRAP_YES:-0}
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) skip=1 ;;
    esac
  done
  if [[ "${skip}" == "1" ]]; then
    echo "${label}: confirmation skipped (BOOTSTRAP_YES=1 or -y/--yes)."
    return 0
  fi

  cat <<EOF

────────────────────────────────────────────────────────
 ${label}
────────────────────────────────────────────────────────

This will DESTROY:
$(printf '%s\n' "${destroy_list}" | sed 's/^/  - /')

This will PRESERVE:
$(printf '%s\n' "${preserve_list}" | sed 's/^/  - /')

EOF
  read -r -p "Type 'yes' to continue, anything else to abort: " answer
  if [[ "${answer}" != "yes" ]]; then
    echo "Aborted — no destructive action taken."
    exit 1
  fi
}

uninstall_k3s_over_ssh() {
  # Called by bootstrap-k3s as a belt-and-suspenders after `terraform destroy`.
  # `terraform destroy` already invokes the module's destroy-time provisioner
  # which runs `/usr/local/bin/k3s-uninstall.sh` on the remote — but that
  # provisioner is marked `on_failure = continue` (so a stale state does not
  # block destroy). If it silently skipped, k3s is still running. This helper
  # re-runs the uninstaller directly via SSH and tolerates "no k3s here" by
  # checking for the script first.
  local ssh_host="${TF_VAR_ssh_host:-}"
  local ssh_port="${TF_VAR_ssh_port:-22}"
  local ssh_user="${TF_VAR_ssh_user:-}"
  local ssh_key="${TF_VAR_ssh_private_key_path:-}"

  if [[ -z "${ssh_host}" || -z "${ssh_user}" || -z "${ssh_key}" ]]; then
    echo "Step 0.5: Skipping SSH k3s uninstall — ssh_host / ssh_user / ssh_private_key_path not loaded."
    return
  fi

  echo "Step 0.5: Force-uninstalling k3s on ${ssh_user}@${ssh_host}:${ssh_port} (no-op if already gone)..."
  ssh -i "${ssh_key}" -p "${ssh_port}" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=5 \
      "${ssh_user}@${ssh_host}" \
      'if [ -x /usr/local/bin/k3s-uninstall.sh ]; then sudo /usr/local/bin/k3s-uninstall.sh; else echo "  k3s-uninstall.sh not present — nothing to do."; fi' \
    || echo "  SSH uninstall returned non-zero; continuing."
}

SUBCOMMAND="${1:-}"

case "${SUBCOMMAND}" in
  cloudflare-purge)
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"
    purge_cloudflare_tunnel "${CLOUDFLARE_TUNNEL_NAME}"
    ;;

  backup-config)
    # Push the operator's gitignored configuration (.env, the
    # config/ directory) to the same restic repository the
    # in-cluster CronJobs use, under tag `operator-config`. The
    # repo URL + passphrase + B2 credentials are sourced from
    # `terraform output` (which already has them after the first
    # apply that brought the backup module up). Idempotent —
    # restic dedup makes a no-op push when nothing changed.
    set +x
    : "${TF_VAR_backup_b2_access_key_id:?TF_VAR_backup_b2_access_key_id must be set in .env}"
    : "${TF_VAR_backup_b2_secret_access_key:?TF_VAR_backup_b2_secret_access_key must be set in .env}"
    if ! command -v restic >/dev/null 2>&1; then
      echo "tf: restic CLI not found — install via your distro's package manager (apt-get install restic / brew install restic)" >&2
      exit 1
    fi
    cd "${SCRIPT_DIR}"
    # Step 1: pull TF state with the existing tfstate-bucket
    # credentials (whichever AWS_ACCESS_KEY_ID / SECRET the
    # operator's `.env` is loading for the S3 backend). The state
    # already lives in the B2 tfstate bucket, but backing the JSON
    # dump up via restic into the *backup* bucket gives a third
    # copy under a separate B2 key — full disaster recovery
    # doesn't have to assume the tfstate key/bucket survived.
    SNAPSHOT="${SCRIPT_DIR}/terraform.tfstate.snapshot.json"
    CLUSTER_SNAPSHOT="${SCRIPT_DIR}/cluster.tfstate.snapshot.json"
    cleanup_snapshot() { rm -f "${SNAPSHOT}" "${CLUSTER_SNAPSHOT}"; }
    # Chain with the wrapper's cleanup instead of replacing it, and keep the
    # plaintext state snapshot private while it exists.
    trap 'cleanup_snapshot; cleanup' EXIT
    umask 077
    echo "tf: terraform state pull -> $(basename "${SNAPSHOT}")"
    terraform state pull > "${SNAPSHOT}"
    # The cluster stack's state, when that stack is initialised here.
    if [[ -d "${SCRIPT_DIR}/cluster/.terraform" ]]; then
      echo "tf: terraform -chdir=cluster state pull -> $(basename "${CLUSTER_SNAPSHOT}")"
      terraform -chdir="${SCRIPT_DIR}/cluster" state pull > "${CLUSTER_SNAPSHOT}"
    fi

    # Step 2: pull restic repo URL + passphrase from outputs.
    REPO_URL="$(terraform output -raw backup_repository_url 2>/dev/null)"
    PASSPHRASE="$(terraform output -raw backup_passphrase 2>/dev/null)"
    if [[ -z "${REPO_URL}" || -z "${PASSPHRASE}" ]]; then
      echo "tf: backup outputs not populated — run ./tf apply with services.backup.enabled = true first" >&2
      exit 1
    fi

    # Step 3: switch AWS_* env to the backup-bucket key for the
    # restic push. Done AFTER `terraform state pull` so the state
    # call still uses the tfstate-bucket key. Per the
    # `services.backup` design, the two keys are intentionally
    # separate — a tfstate-key compromise must not delete or
    # overwrite encrypted backups.
    export RESTIC_REPOSITORY="${REPO_URL}"
    export RESTIC_PASSWORD="${PASSPHRASE}"
    export AWS_ACCESS_KEY_ID="${TF_VAR_backup_b2_access_key_id}"
    export AWS_SECRET_ACCESS_KEY="${TF_VAR_backup_b2_secret_access_key}"

    TARGETS=(.env config "$(basename "${SNAPSHOT}")" "$(basename "${CLUSTER_SNAPSHOT}")")
    EXISTING=()
    for t in "${TARGETS[@]}"; do
      if [[ -e "$t" ]]; then EXISTING+=("$t"); fi
    done
    if [[ ${#EXISTING[@]} -eq 0 ]]; then
      echo "tf: nothing to back up (.env / config / state absent)" >&2
      exit 1
    fi
    echo "tf: restic backup --tag operator-config ${EXISTING[*]}"
    restic backup --tag operator-config --host platform-operator-config "${EXISTING[@]}"
    ;;

  bootstrap-minikube)
    shift
    preflight_config_files
    MINIKUBE_PROFILE="$(resolve_cluster_name)"
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"
    preflight_no_existing_cf_tunnel "${CLOUDFLARE_TUNNEL_NAME}"

    confirm_bootstrap_destructive \
      "Bootstrap: minikube (Option A) — cluster \"${MINIKUBE_PROFILE}\"" \
      "minikube profile \"${MINIKUBE_PROFILE}\" — the docker-driver VM container plus ${HOME}/.minikube/profiles/${MINIKUBE_PROFILE} and ${HOME}/.minikube/machines/${MINIKUBE_PROFILE}
local Terraform state of both stacks — ${SCRIPT_DIR}/terraform.tfstate, ${SCRIPT_DIR}/terraform.tfstate.backup, ${SCRIPT_DIR}/.terraform.tfstate.lock.info and the same under ${SCRIPT_DIR}/cluster/" \
      "host volume data at ${TF_VAR_host_volume_path:-${HOST_VOLUME_PATH:-/data/vol}} — tenant PVCs on disk survive
Cloudflare tunnel \"${CLOUDFLARE_TUNNEL_NAME}\" and its DNS CNAMEs — bootstrap does NOT touch Cloudflare. If you want to destroy them, run './tf cloudflare-purge' as a deliberate separate step
remote tfstate in B2 if the remote backend was ever configured (local backend override wins while active)" \
      "$@"

    lock_state_for "${SUBCOMMAND}"
    echo "=== Phased Bootstrap Mode (minikube / Option A) ==="
    reset_minikube_profile "${MINIKUBE_PROFILE}"
    reset_terraform_state

    echo "Step 1: Creating Minikube cluster first (cluster stack)..."
    cluster_terraform apply -auto-approve

    echo "Step 1.5: Neutralising kicbase's bundled podman stack (fights Flannel for 10.244.0.1)..."
    if docker ps --format '{{.Names}}' | grep -q "^${MINIKUBE_PROFILE}$"; then
      # Kicbase bundles the full podman runtime — `deploy/kicbase/Dockerfile`
      # in kubernetes/minikube does `clean-install podman catatonit crun` and
      # `systemctl enable podman.socket`. It is there for the `--driver=podman`
      # code path and for operators who `minikube ssh` in to run `podman` by
      # hand. On our `--driver=docker` stack it is dead weight — and
      # actively harmful.
      #
      # The harm chain: podman.socket is a systemd socket-activation unit
      # listening on /run/podman/podman.sock. Anything that pings that
      # socket (containerd CNI-reload loops, crictl probes, kubelet probing
      # its known runtime sockets) wakes podman.service. podman.service on
      # first start creates its default network named `podman` — a bridge
      # called cni-podman0 with `10.244.0.1/16`. That is the SAME address
      # Flannel wants on `cni0` (`10.244.0.1/24`). ARP goes
      # non-deterministic, then a few minutes into the bootstrap
      # in-cluster Service NAT collapses: coredns, metrics-server and
      # kubernetes-dashboard start looping on
      # `dial tcp 100.64.0.1:443: no route to host`.
      #
      # We learned this step-wise. First: disable the CNI conflist by
      # renaming to `.disabled` — bridge came back. Second: `rm` the
      # conflist + `systemctl restart containerd` (per upstream issues
      # #11194 / #8480) — bridge STILL came back a few minutes later,
      # reproduced identically on a fresh Mac cluster. Third (this): nuke
      # the podman stack whole. No socket → nothing wakes the service;
      # no binary → no code path creates the network; no network database
      # → if something manages to start podman-in-a-chroot, it cannot
      # reconstitute the network. The bridge goes away for good.
      #
      # The trade-off is narrow: inside THIS kicbase container `minikube
      # ssh -- podman run …` and `--driver=podman` no longer work. We do
      # not use either, so the trade is free. Every `minikube delete` +
      # `bootstrap` starts a fresh kicbase container where we run this
      # again — the disable persists only for the lifetime of the node.
      echo "  Removing podman stack (socket, timers, one-shot services, binaries, CNI configs) from ${MINIKUBE_PROFILE}..."
      docker exec "${MINIKUBE_PROFILE}" bash -c '
        # Every podman-flavoured systemd unit, not just .socket. Kicbase ships:
        #   podman.socket                — socket activation (wakes podman.service)
        #   podman.service               — the actual daemon
        #   podman-restart.service       — one-shot at boot, calls `podman container start --all`
        #                                  which initialises the default network and creates
        #                                  cni-podman0 as a side effect BEFORE our Step 1.5
        #                                  has had a chance to run
        #   podman-auto-update.timer     — periodic, pings podman
        #   podman-auto-update.service   — the work the timer fires
        #   podman-clean-transient.service — cleanup, also invokes podman
        # `mask` instead of `disable --now` so nothing can re-enable them implicitly
        # (tmpfiles, package post-install, cattle-style automation).
        for unit in podman.socket podman.service \
                    podman-restart.service \
                    podman-auto-update.timer podman-auto-update.service \
                    podman-clean-transient.service; do
          systemctl stop "$unit"    2>/dev/null
          systemctl disable "$unit" 2>/dev/null
          systemctl mask "$unit"    2>/dev/null
        done

        # Remove every binary / wrapper that could reconstitute the network.
        # `netavark` is the podman 4.x network backend (replaces the CNI
        # conflist path entirely); `aardvark-dns` is its DNS companion.
        # Killing netavark is load-bearing — without it, even a stray podman
        # invocation would fail before touching netlink.
        rm -f /usr/bin/podman \
              /usr/libexec/podman/rootlessport \
              /usr/libexec/podman/catatonit \
              /usr/libexec/podman/netavark \
              /usr/libexec/podman/aardvark-dns \
              /usr/lib/podman/* \
              2>/dev/null || true

        # Wipe every on-disk network database podman / netavark / CNI might
        # read back from on restart.
        rm -rf /etc/containers/networks \
               /var/lib/containers/storage/networks \
               /var/lib/cni/networks/podman \
               /var/lib/cni/results/podman \
               /run/netns/podman* 2>/dev/null || true

        # Remove the podman CNI conflist outright (not rename). Renaming
        # leaves the file findable by anything doing `ls /etc/cni/net.d/*`
        # without a pattern filter.
        rm -f /etc/cni/net.d/87-podman-bridge.conflist

        # Tear down any cni-podman0 bridge that the pre-Step-1.5 boot run
        # of podman-restart.service already created. `ip link delete` fails
        # silently while slave veths from coredns / kube-proxy / etc. are
        # still attached, so fall back to flush-IP + link-down as the
        # always-works disarm.
        ip link delete cni-podman0 2>/dev/null || {
          ip addr flush dev cni-podman0 2>/dev/null
          ip link set cni-podman0 down 2>/dev/null
        }
      '

      # Stale Flannel interfaces from a previous cluster run block a fresh
      # Flannel start ("cni0 already has an IP address different from
      # 10.244.0.1/24"). Delete outright so Flannel recreates clean.
      echo "  Deleting stale cni0 / flannel.1 on ${MINIKUBE_PROFILE}..."
      docker exec "${MINIKUBE_PROFILE}" ip link delete cni0 2>/dev/null || true
      docker exec "${MINIKUBE_PROFILE}" ip link delete flannel.1 2>/dev/null || true

      # containerd caches CNI plugin configs at startup. Force a rescan so
      # it picks up that /etc/cni/net.d/ now has only `10-flannel.conflist`
      # and drops any in-memory reference to the podman-bridge plugin.
      echo "  Restarting containerd to flush its CNI-plugin cache..."
      docker exec "${MINIKUBE_PROFILE}" systemctl restart containerd

      # Wait for Flannel to be Ready before proceeding — ensures
      # /run/flannel/subnet.env exists so every pod created in Step 2
      # uses the correct Flannel CNI from the start.
      echo "  Waiting for Flannel DaemonSet to be Ready..."
      kubectl wait --for=condition=ready pod \
        -n kube-flannel -l app=flannel \
        --timeout=120s 2>/dev/null || \
      kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=120s

      # kube-system pods (coredns, metrics-server) were created by kubeadm
      # attached to cni-podman0 and have lost in-cluster connectivity.
      # Kick them so they re-attach to cni0 (Flannel) under the refreshed
      # containerd CNI view.
      echo "  Restarting kube-system deployments to pick up Flannel CNI..."
      kubectl rollout restart deployment -n kube-system 2>/dev/null || true
      kubectl rollout status deployment -n kube-system --timeout=120s 2>/dev/null || true
    fi

    PLATFORM_NS="${TF_VAR_namespace_prefix:-}platform"

    echo "Step 1.7: Deploying shared MySQL before project modules..."
    terraform apply -target=module.mysql -auto-approve

    echo "  Waiting for MySQL to be Ready..."
    kubectl wait --for=condition=ready pod \
      -n "${PLATFORM_NS}" -l app=mysql \
      --timeout=180s

    echo "Step 2: Applying the rest of the platform..."
    terraform apply -auto-approve
    ;;

  bootstrap-k3s)
    shift
    preflight_config_files
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"
    preflight_no_existing_cf_tunnel "${CLOUDFLARE_TUNNEL_NAME}"

    confirm_bootstrap_destructive \
      "Bootstrap: k3s (Option B) — ssh target \"${TF_VAR_ssh_user:-?}@${TF_VAR_ssh_host:-?}\"" \
      "the k3s cluster on ${TF_VAR_ssh_user:-?}@${TF_VAR_ssh_host:-?}:${TF_VAR_ssh_port:-22} — \`terraform destroy\` then \`/usr/local/bin/k3s-uninstall.sh\` over SSH. All pods, Services, PVCs, in-cluster data disappear with k3s
local Terraform state of both stacks — ${SCRIPT_DIR}/terraform.tfstate, ${SCRIPT_DIR}/terraform.tfstate.backup, ${SCRIPT_DIR}/.terraform.tfstate.lock.info and the same under ${SCRIPT_DIR}/cluster/" \
      "host volume data at ${TF_VAR_host_volume_path:-${HOST_VOLUME_PATH:-/data/vol}} on ${TF_VAR_ssh_host:-?} — k3s hostPath PVs survive because only the k3s control plane / kubelet are uninstalled, not the directory tree
the SSH host itself — OS, user accounts, other services running on ${TF_VAR_ssh_host:-?} are untouched
Cloudflare zones and DNS records outside Terraform — but NOTE: the Cloudflare tunnel \"${CLOUDFLARE_TUNNEL_NAME}\" and its Terraform-managed DNS CNAMEs ARE destroyed by the \`terraform destroy\` step and recreated (new tunnel ID) by the apply
database / mail credentials — Terraform state is reset, so passwords are regenerated; MySQL/Postgres re-assert the new superuser passwords on start and tenant setup Jobs re-assert theirs, but other app-held secrets stored in the volumes keep their old values" \
      "$@"

    lock_state_for "${SUBCOMMAND}"
    echo "=== Single-phase Bootstrap Mode (k3s / Option B) ==="
    echo "Step 0: Destroying existing Terraform state (if any): platform, then cluster..."
    terraform destroy -auto-approve
    cluster_terraform destroy -auto-approve

    uninstall_k3s_over_ssh
    reset_terraform_state

    echo "Step 1: Installing k3s (cluster stack)..."
    cluster_terraform apply -auto-approve

    echo "Step 2: Applying platform..."
    terraform apply -auto-approve
    ;;

  lock-status)
    show_state_lock
    ;;

  unlock)
    remove_state_lock
    ;;

  cluster)
    shift
    # The cluster stack has its own state on its own backend, so its own lock.
    STATE_LOCK_STACK_DIR="${SCRIPT_DIR}/cluster"
    STATE_LOCK_CMD="./tf cluster"
    case "${1:-}" in
      lock-status) show_state_lock ;;
      unlock) remove_state_lock ;;
      *)
        # Initialise first: the lock reads the backend that init records.
        if [[ "${1:-}" != "init" && ! -d "${SCRIPT_DIR}/cluster/.terraform" ]]; then
          terraform -chdir="${SCRIPT_DIR}/cluster" init -input=false
        fi
        if state_lock_needed "$@"; then
          lock_state_for "cluster $*"
        fi
        cluster_terraform "$@"
        ;;
    esac
    ;;

  bootstrap)
    cat >&2 <<'EOF'
The generic `./tf bootstrap` subcommand was split by distribution. Pick one:
  ./tf bootstrap-minikube   (Option A in cluster/main.tf)
  ./tf bootstrap-k3s        (Option B in cluster/main.tf)
EOF
    exit 2
    ;;

  *)
    if state_lock_needed "$@"; then
      lock_state_for "$*"
    fi
    start_zitadel_port_forward
    echo "Running: terraform $*" >&2
    terraform "$@"
    ;;
esac
