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
# Subcommands with extra orchestration:
#   ./tf cloudflare-purge
#     Deletes the platform Cloudflare tunnel + any DNS CNAMEs that still point
#     at *.cfargotunnel.com. Useful when Terraform state was wiped mid-apply
#     and the tunnel or DNS records were orphaned on the Cloudflare side.
#
#   ./tf bootstrap-minikube
#     Full-reset flow for the minikube distribution (Option A in main.tf):
#     resets the local minikube profile, wipes Terraform state, purges the
#     Cloudflare tunnel, and runs a phased apply (cluster first, then MySQL,
#     then the rest) with Flannel/CNI cleanup between phases. Host volume
#     data is NOT deleted — it survives.
#
#   ./tf bootstrap-k3s
#     Full-reset flow for the k3s distribution (Option B in main.tf):
#     `terraform destroy` (tears down the tunnel + tries SSH uninstall of k3s),
#     force-uninstalls k3s over SSH in case the destroy-time provisioner was
#     skipped, wipes Terraform state, purges the Cloudflare tunnel, then runs
#     a single-phase `terraform apply` (k3s single-phase works with lazy
#     `config_path` providers). Host volume data under `$HOST_VOLUME_PATH` is
#     NOT deleted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Warning: $ENV_FILE not found"
else
  echo "Loading variables from .env as TF_VAR_*..."
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
      #   FOO_BAR=...        (plain)       → exported as TF_VAR_foo_bar
      #   TF_VAR_foo_bar=... (pre-fixed)   → exported as-is (just lowercased)
      # Without this branch, pre-fixed keys would double up as
      # TF_VAR_tf_var_foo_bar and the variable would silently not reach
      # Terraform. The .env.example uses the pre-fixed style for the k3s SSH
      # knobs because that is the idiomatic Terraform env-var form.
      lower_key="$(echo "$key" | tr '[:upper:]' '[:lower:]')"
      if [[ "$lower_key" == tf_var_* ]]; then
        tf_var_name="TF_VAR_${lower_key#tf_var_}"
      else
        tf_var_name="TF_VAR_${lower_key}"
      fi
      export "$tf_var_name"="$value"
      echo "  $tf_var_name=*** (hidden)"
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
  rm -f "${state_path}" "${backup_path}" "${lock_path}"
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

  bootstrap-minikube)
    echo "=== Phased Bootstrap Mode (minikube / Option A) ==="
    MINIKUBE_PROFILE="$(resolve_cluster_name)"
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"

    reset_minikube_profile "${MINIKUBE_PROFILE}"
    reset_terraform_state
    purge_cloudflare_tunnel "${CLOUDFLARE_TUNNEL_NAME}"

    echo "Step 1: Creating Minikube cluster first..."
    terraform apply -target=module.k8s.minikube_cluster.this -auto-approve

    echo "Step 1.5: Cleaning stale CNI interfaces and disabling conflicting podman bridge CNI..."
    if docker ps --format '{{.Names}}' | grep -q "^${MINIKUBE_PROFILE}$"; then
      # Remove stale Flannel bridge interfaces left from a previous cluster run.
      # If cni0 still has an IP from before, Flannel refuses to start with:
      # "cni0 already has an IP address different from 10.244.0.1/24"
      echo "  Removing stale cni0 and flannel.1 from ${MINIKUBE_PROFILE}..."
      docker exec "${MINIKUBE_PROFILE}" ip link delete cni0 2>/dev/null || true
      docker exec "${MINIKUBE_PROFILE}" ip link delete flannel.1 2>/dev/null || true

      # The kicbase image ships 87-podman-bridge.conflist alongside 10-flannel.conflist.
      # Both use 10.244.0.1 as gateway. Before Flannel is ready, pods created by kubelet
      # pick up the podman bridge config (because the Flannel CNI plugin fails when
      # /run/flannel/subnet.env does not yet exist). Those pods land on cni-podman0 where
      # ARP for the gateway never resolves -> no in-cluster connectivity.
      # Disabling the podman config here ensures all pods use Flannel exclusively.
      echo "  Disabling podman bridge CNI config in ${MINIKUBE_PROFILE}..."
      docker exec "${MINIKUBE_PROFILE}" \
        mv /etc/cni/net.d/87-podman-bridge.conflist \
           /etc/cni/net.d/87-podman-bridge.conflist.disabled 2>/dev/null || true

      # Wait for Flannel to be Ready before proceeding — ensures /run/flannel/subnet.env
      # exists so all pods created in Step 2 use the correct Flannel CNI from the start.
      echo "  Waiting for Flannel DaemonSet to be Ready..."
      kubectl wait --for=condition=ready pod \
        -n kube-flannel -l app=flannel \
        --timeout=120s 2>/dev/null || \
      kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=120s

      # kube-system pods (coredns, metrics-server) are created by kubeadm during Step 1,
      # before the podman bridge is disabled. They land on cni-podman0 and lose in-cluster
      # connectivity. Restart them now so they re-attach to cni0 (Flannel).
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
    echo "=== Single-phase Bootstrap Mode (k3s / Option B) ==="
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"

    echo "Step 0: Destroying existing Terraform state (if any)..."
    terraform destroy -auto-approve

    uninstall_k3s_over_ssh
    reset_terraform_state
    purge_cloudflare_tunnel "${CLOUDFLARE_TUNNEL_NAME}"

    echo "Step 1: Applying platform (single phase — k3s providers are config_path-lazy)..."
    terraform apply -auto-approve
    ;;

  bootstrap)
    cat >&2 <<'EOF'
The generic `./tf bootstrap` subcommand was split by distribution. Pick one:
  ./tf bootstrap-minikube   (Option A in main.tf)
  ./tf bootstrap-k3s        (Option B in main.tf)
EOF
    exit 2
    ;;

  *)
    echo "Running: terraform $*"
    terraform "$@"
    ;;
esac
