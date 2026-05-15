# Runbook: migrate a k3s cluster from IPv4-only to dual-stack

In-place migration. No cluster reinstall, no PV/PVC re-provisioning.
Per-node downtime ~30s for the kubelet/CNI restart; ~30s control-plane
unavailability per server-node restart. Total wall-clock ~4-6 hours
on a small (≤5-node) cluster going carefully.

## Prerequisites

- k3s ≥ 1.31 (dual-stack stable since 1.27, but flannel v6 fixes
  landed across 1.30/1.31 — 1.34 is the recommended floor).
- Every node has IPv6 connectivity on its primary interface
  (whether public, private, or a WireGuard tunnel that carries v6).
- A free `/56` IPv6 prefix to use for the cluster pod CIDR (e.g.
  ULA `fd00:42::/56` for cluster-local, or a delegated `/56` from
  your ISP if Pods need to be globally addressable on the LAN).
- A free `/112` for the service CIDR (e.g. `fd00:43::/112`).
  Service IPs are virtual, ULA is fine even if Pods use GUA.
- Operator has root SSH on every node.

## Reverse story

If something goes wrong, removing the v6 CIDRs from the k3s flags
and restarting the control plane gets you back to single-stack.
Existing v4 functionality is untouched throughout.

## Phase 1 — pre-flight on each node

For every node (control-plane + agent), assign an IPv6 address on
the primary cluster interface. If the cluster runs over WireGuard,
edit `/etc/wireguard/wg0.conf` (or whichever interface k3s binds to)
to add a v6 address alongside the existing v4:

```ini
[Interface]
Address = 10.x.x.X/24, fd00:23::X/64    # X is unique per node
```

Apply with `wg-quick down wg0 && wg-quick up wg0`. Verify with
`ip -6 addr show wg0` — the new address must be present and pingable
from another node:

```bash
ping6 -I wg0 fd00:23::Y                  # Y = another node's v6 in mesh
```

If pings fail, fix mesh connectivity before proceeding — k3s won't
help diagnose this layer.

## Phase 2 — control-plane (k3s server nodes)

For each k3s server, edit the systemd unit env file (path varies
between operator wrappers; common is
`/etc/systemd/system/k3s.service.env` or your install script's
output). Add v6 CIDRs alongside the existing v4 ones:

```
INSTALL_K3S_EXEC="server \
  --cluster-cidr=10.42.0.0/16,fd00:42::/56 \
  --service-cidr=10.43.0.0/16,fd00:43::/112 \
  --node-ip=10.x.x.X,fd00:23::X \
  ...other existing flags..."
```

Then `systemctl daemon-reload && systemctl restart k3s`. Wait until
`kubectl get nodes` shows the node `Ready` again (~30s). API server
is briefly unavailable; downtime is the restart window.

Roll one server at a time. If you have a single-server cluster, the
restart window is the entire cluster's API downtime — workloads
already running keep running, but no scheduling decisions happen
in that window. Schedule for low-traffic.

## Phase 3 — kubelet (agent nodes)

Same idea on each agent: edit the agent's env file, add
`--node-ip=10.x.x.X,fd00:23::X`. Restart with `systemctl restart
k3s-agent`. Agent unavailable ~30s; Pods on that node keep running
until k3s drains them, which doesn't happen on a clean restart.
Verify the node has dual addresses:

```bash
kubectl get node <name> -o jsonpath='{.status.addresses}' | jq
# expect entries with type "InternalIP" — one v4, one v6
```

## Phase 4 — flannel (CNI) v6 enablement

k3s ships flannel by default. The flannel ConfigMap lives in
`kube-flannel` ns (or `kube-system` on older k3s). Add v6 networking:

```bash
kubectl -n kube-flannel get cm kube-flannel-cfg -o yaml \
  > /tmp/flannel-cfg.bak.yaml
kubectl -n kube-flannel edit cm kube-flannel-cfg
```

In the `net-conf.json` data field, set:

```json
{
  "Network":      "10.42.0.0/16",
  "IPv6Network":  "fd00:42::/56",
  "EnableIPv6":   true,
  "Backend":      { "Type": "vxlan" }
}
```

Restart flannel pods cluster-wide:

```bash
kubectl -n kube-flannel rollout restart ds kube-flannel-ds
```

Verify each Pod gets a v6 by spawning a fresh test:

```bash
kubectl run -n default v6-test --rm -i --restart=Never \
  --image=alpine --command -- ip -6 addr show eth0
# expect a fd00:42:... address on eth0
```

**Known flannel gotcha**: pre-1.30 k3s shipped a flannel build with
broken v6 routing across nodes (Pods on the same node could v6, but
cross-node v6 dropped). 1.31+ is fine. If you're stuck on an older
k3s, the migration to Cilium is the cleanest answer (Cilium DS
replaces flannel, you uninstall the latter).

## Phase 5 — kube-proxy / CoreDNS

k3s bundles kube-proxy with the API server flags above; nothing
extra needed. CoreDNS is auto-configured by k3s and starts handing
out AAAA records as soon as Services have v6 ClusterIPs.

Smoke test DNS from a Pod:

```bash
kubectl run -n default dns-test --rm -i --restart=Never \
  --image=alpine --command -- nslookup -q=AAAA kubernetes.default
```

## Phase 6 — opt existing Services into dual-stack

By default, `Service` is `IPFamilyPolicy: SingleStack` for backwards
compat. New Services you create now can be:

```yaml
spec:
  ipFamilyPolicy: PreferDualStack
  ipFamilies: [IPv4, IPv6]
```

For each existing Service you want dual:

```bash
kubectl -n <ns> patch svc <name> --type=merge -p \
  '{"spec":{"ipFamilyPolicy":"PreferDualStack","ipFamilies":["IPv4","IPv6"]}}'
```

Headless Services (`clusterIP: None`) gain v6 endpoints automatically
once the underlying Pods have v6.

## Phase 7 — opt existing Pods into v6

Pods get a v6 address only on **recreate**. Existing Pods stay
v4-only until their owning controller spins fresh ones. To force-
propagate, do rolling restarts of every Deployment/StatefulSet you
care about:

```bash
for ns in <list of relevant ns>; do
  for kind in deployment statefulset daemonset; do
    kubectl -n $ns rollout restart $kind --all
  done
done
```

This is the slowest phase because each rollout has its own pacing.
Skip workloads where you don't care (legacy single-stack is harmless
in a dual-stack cluster).

## Phase 8 — external reach (Ingress + LoadBalancer)

What lives outside the cluster doesn't auto-migrate. Three pieces:

1. **MetalLB v6 pools**: add a second `IPAddressPool` CR with v6
   CIDRs (e.g. `fd00:fe00::/120` if ULA, or your delegated GUA
   range for public reach), plus a matching `L2Advertisement`.
   Existing Services that want a v6 VIP get patched to
   `ipFamilyPolicy: PreferDualStack` AND request a v6 IP via
   `metallb.io/loadBalancerIPs` annotation.

2. **DNS records**: tenant hostnames currently CNAMEd at
   `<tunnel-id>.cfargotunnel.com` (Cloudflare Tunnel) work
   transparently for v6 — Cloudflare bridges. Direct-IP hostnames
   (services bypassing CF Tunnel) need explicit AAAA records
   pointing at the new MetalLB v6 VIP.

3. **Cloudflare Tunnel**: cloudflared bridges v4↔v6 transparently;
   no changes needed for Cloudflare Tunnel-fronted hostnames.

## Phase 9 — observability

Confirm dual-stack is healthy across the cluster:

```bash
# Every node has v4 + v6 InternalIP:
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{":\n"}{range .status.addresses[?(@.type=="InternalIP")]}  {.address}{"\n"}{end}{end}'

# CoreDNS resolves AAAA for cluster-internal names:
kubectl run -n default ddns --rm -i --restart=Never \
  --image=alpine --command -- nslookup -q=AAAA kubernetes.default

# Flannel reports v6 backend:
kubectl -n kube-flannel logs ds/kube-flannel-ds | grep -i ipv6 | head

# A Service patched to dual-stack returns BOTH cluster IPs:
kubectl get svc -n <ns> <name> -o jsonpath='{.spec.clusterIPs}'
# expect: ["10.43.x.x", "fd00:43::x"]
```

If any of those return single-stack, walk back through the phase
that owns the missing layer.

## Rollback

If something breaks irrecoverably mid-migration:

1. Revert the k3s server's `--cluster-cidr` and `--service-cidr` to
   the v4-only forms (drop the `,fd00:...` suffixes).
2. Revert the kubelet `--node-ip` to v4-only.
3. Restart k3s + k3s-agent on each node.
4. Revert the flannel ConfigMap (`kubectl apply -f /tmp/flannel-cfg.bak.yaml`).
5. Restart the flannel DaemonSet.

Existing Pods/Services that gained v6 lose those addresses on
their next recreate. v4 functionality continues unaffected.

## When NOT to migrate

- Cluster is on k3s < 1.30 — flannel v6 is too flaky; bump k3s
  first, separate maintenance window.
- Operator's WG mesh / underlay doesn't support v6 — fix that
  first; migration without underlay v6 is busywork.
- No use case planned within ~3 months — Pods on a dual-stack
  cluster don't HURT anything, but the maintenance burden of "now
  I have to think about both stacks" is real. If nothing in the
  near-term roadmap needs v6, defer.

## After migration — what new becomes possible

- Pull v6-only container registries (rare today, but trending).
- Outbound mail with v6 PTR for reputation gains.
- Matrix federation v6 endpoints — homeservers prefer v6 when both
  available.
- SIP/RTP over v6 for partners that support it (avoids NAT
  traversal entirely on the v6 path).
- Per-Pod globally addressable v6 if you delegate a real GUA
  prefix — no more SNAT funnel for outbound, simpler audit logs.
