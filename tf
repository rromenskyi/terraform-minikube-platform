#!/usr/bin/env bash
# Terraform wrapper that loads .env and supports phased bootstrap
# Usage:
#   ./tf plan
#   ./tf apply
#   ./tf bootstrap     # reset local minikube + local terraform state, purge stale tunnel, then apply

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
      tf_var_name="TF_VAR_$(echo "$key" | tr '[:upper:]' '[:lower:]')"
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

purge_cloudflare_dns_records() {
  local api_token="${TF_VAR_cloudflare_api_token:-}"

  if [[ -z "${api_token}" ]]; then
    echo "Step 0.5: Skipping Cloudflare DNS purge (no token)."
    return
  fi

  # Fetch all zones the token has access to — covers every domain we manage.
  local zone_ids
  zone_ids="$(curl -fsS \
    -H "Authorization: Bearer ${api_token}" \
    "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    | jq -r '.result[]?.id')"

  if [[ -z "${zone_ids}" ]]; then
    echo "Step 0.5: No Cloudflare zones found, skipping DNS purge."
    return
  fi

  echo "Step 0.5: Purging stale Cloudflare tunnel DNS records across all zones..."
  while IFS= read -r zone_id; do
    [[ -n "${zone_id}" ]] || continue
    local api_url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"

    # Delete all CNAME records pointing at the Cloudflare tunnel CDN (*.cfargotunnel.com).
    # This covers every hostname we manage without hardcoding names.
    local tunnel_records
    tunnel_records="$(curl -fsS \
      -H "Authorization: Bearer ${api_token}" \
      "${api_url}?type=CNAME&per_page=100" \
      | jq -r '.result[]? | select(.content | endswith("cfargotunnel.com")) | "\(.id) \(.name)"')"

    [[ -n "${tunnel_records}" ]] || continue

    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      local rid name
      rid="${line%% *}"
      name="${line#* }"
      echo "  Deleting CNAME '${name}' (${rid}) in zone ${zone_id}..."
      curl -fsS -X DELETE \
        -H "Authorization: Bearer ${api_token}" \
        "${api_url}/${rid}" >/dev/null
    done <<< "${tunnel_records}"
  done <<< "${zone_ids}"
}

if [[ "${1:-}" == "bootstrap" ]]; then
  echo "=== Phased Bootstrap Mode ==="
  MINIKUBE_PROFILE="$(resolve_cluster_name)"
  CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"

  reset_minikube_profile "${MINIKUBE_PROFILE}"
  reset_terraform_state
  purge_cloudflare_tunnel "${CLOUDFLARE_TUNNEL_NAME}"
  purge_cloudflare_dns_records

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
else
  echo "Running: terraform $*"
  terraform "$@"
fi
