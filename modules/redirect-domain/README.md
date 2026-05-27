# `redirect-domain`

Zone-wide HTTP 308 (permanent) redirect to a canonical target, served
by Traefik in-cluster.
Two K8s resources, no Service, no pod — Traefik does the redirect on
the wire. Survives a Cloudflare exit unchanged: when DNS flips from
CF Tunnel CNAME to a direct A-record at the platform's public IP, the
same IngressRoute keeps serving.

## What it emits

1. `traefik.io/v1alpha1/Middleware` (`redirect-<from-slug>`) — a
   `redirectRegex` middleware (`permanent: true`) capturing the path
   with `^https?://[^/]+/(.*)` and rebuilding to
   `https://<to_domain>/${1}`. Wire status code is HTTP 308 (Traefik's
   canonical for `permanent`); browsers and search engines treat it
   identically to 301 for canonicalization. Query string preserved
   automatically by Traefik on redirect.
2. `traefik.io/v1alpha1/IngressRoute` (`redirect-<from-slug>`) — matches
   `Host(<from>) || HostRegexp(^.+\.<from>$)` on the `web` entryPoint,
   attaches the middleware, points services at the Traefik built-in
   `noop@internal` (never reached — the middleware returns 301 before
   service dispatch).

Both resources live in `ingress-controller` (the platform's Traefik
namespace) by default.

## Inputs

- `from_domain` — bare apex (e.g. `old.example.com`).
- `to_domain` — bare apex of the canonical target (e.g. `new.example.com`).
- `namespace` — defaults to `ingress-controller`.
- `labels` — propagated to both manifests; usually the platform's
  null-label tag set from the caller.

## Outputs

- `ingressroute_name` — for cross-reference in `kubectl get ingressroute`.

## Required upstream wiring (NOT this module's job)

For requests to actually reach Traefik, the source domain has to route
to the platform. Today, via Cloudflare Tunnel:

1. DNS — apex + wildcard CNAME on the source zone pointed at the
   tunnel's `<uuid>.cfargotunnel.com`. Proxied.
2. cloudflared ingress — entries matching `<from_domain>` and
   `*.<from_domain>` routed to `http://traefik.ingress-controller.svc.cluster.local:80`.

The platform engine handles both in `cloudflare.tf` by reading the
domain yaml's `redirect_to:` field and folding apex + wildcard into the
existing tunnel ingress + DNS CNAME for_each machinery.

## Typical use

Operator-side yaml (engine wiring in `redirect_domains.tf` filters
domain configs that carry a top-level `redirect_to:` field):

```yaml
# config/domains/old.example.com.yaml
name: old.example.com
slug: old-example-com
cloudflare_zone_id: "<zone-id-from-cf>"
dnssec_enabled: true

redirect_to: new.example.com
```

That alone is enough — engine instantiates this module for every
opted-in domain.

## Why path + query preservation matters

A naive `Location: https://canonical/` 301 throws away the user's URL.
The regex captures everything after the host and rebuilds the path on
the new origin; Traefik passes the query string through on the
redirect. So
`https://old.example.com/some/deep/page?utm_source=x` lands at
`https://new.example.com/some/deep/page?utm_source=x`.
