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
#   ./tf bootstrap-minikube [-y|--yes]
#     Full-reset flow for the minikube distribution (Option A in main.tf):
#     resets the local minikube profile, wipes local Terraform state, runs a
#     phased apply (cluster first, then MySQL, then the rest) with
#     Flannel/CNI cleanup between phases. Host volume data is NOT deleted —
#     it survives. Cloudflare tunnel / DNS are NOT touched by this command —
#     if an existing tunnel with the same name is found in the operator's
#     account, bootstrap aborts with a pointer to `./tf cloudflare-purge`
#     (nuke) or `terraform import` (adopt).
#
#   ./tf bootstrap-k3s [-y|--yes]
#     Full-reset flow for the k3s distribution (Option B in main.tf):
#     `terraform destroy` (tears down the tunnel + tries SSH uninstall of k3s),
#     force-uninstalls k3s over SSH in case the destroy-time provisioner was
#     skipped, wipes local Terraform state, then runs a single-phase
#     `terraform apply` (k3s single-phase works with lazy `config_path`
#     providers). Host volume data under `$HOST_VOLUME_PATH` is NOT deleted.
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

  bootstrap-minikube)
    shift
    preflight_config_files
    MINIKUBE_PROFILE="$(resolve_cluster_name)"
    CLOUDFLARE_TUNNEL_NAME="$(resolve_cloudflare_tunnel_name)"
    preflight_no_existing_cf_tunnel "${CLOUDFLARE_TUNNEL_NAME}"

    confirm_bootstrap_destructive \
      "Bootstrap: minikube (Option A) — cluster \"${MINIKUBE_PROFILE}\"" \
      "minikube profile \"${MINIKUBE_PROFILE}\" — the docker-driver VM container plus ${HOME}/.minikube/profiles/${MINIKUBE_PROFILE} and ${HOME}/.minikube/machines/${MINIKUBE_PROFILE}
local Terraform state — ${SCRIPT_DIR}/terraform.tfstate, ${SCRIPT_DIR}/terraform.tfstate.backup, ${SCRIPT_DIR}/.terraform.tfstate.lock.info" \
      "host volume data at ${TF_VAR_host_volume_path:-${HOST_VOLUME_PATH:-/data/vol}} — tenant PVCs on disk survive
Cloudflare tunnel \"${CLOUDFLARE_TUNNEL_NAME}\" and its DNS CNAMEs — bootstrap does NOT touch Cloudflare. If you want to destroy them, run './tf cloudflare-purge' as a deliberate separate step
remote tfstate in B2 if the remote backend was ever configured (local backend override wins while active)" \
      "$@"

    echo "=== Phased Bootstrap Mode (minikube / Option A) ==="
    reset_minikube_profile "${MINIKUBE_PROFILE}"
    reset_terraform_state

    echo "Step 1: Creating Minikube cluster first..."
    terraform apply -target=module.k8s.minikube_cluster.this -auto-approve

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
local Terraform state — ${SCRIPT_DIR}/terraform.tfstate, ${SCRIPT_DIR}/terraform.tfstate.backup, ${SCRIPT_DIR}/.terraform.tfstate.lock.info" \
      "host volume data at ${TF_VAR_host_volume_path:-${HOST_VOLUME_PATH:-/data/vol}} on ${TF_VAR_ssh_host:-?} — k3s hostPath PVs survive because only the k3s control plane / kubelet are uninstalled, not the directory tree
the SSH host itself — OS, user accounts, other services running on ${TF_VAR_ssh_host:-?} are untouched
Cloudflare tunnel \"${CLOUDFLARE_TUNNEL_NAME}\" and its DNS CNAMEs — bootstrap does NOT touch Cloudflare. If you want to destroy them, run './tf cloudflare-purge' as a deliberate separate step" \
      "$@"

    echo "=== Single-phase Bootstrap Mode (k3s / Option B) ==="
    echo "Step 0: Destroying existing Terraform state (if any)..."
    terraform destroy -auto-approve

    uninstall_k3s_over_ssh
    reset_terraform_state

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
