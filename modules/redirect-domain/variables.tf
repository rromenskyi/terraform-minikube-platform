variable "from_domain" {
  description = "Source domain name (apex), e.g. `old.example.com`. The emitted IngressRoute matches both the apex and `*.from_domain` via Host + HostRegexp predicates."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.from_domain))
    error_message = "from_domain must look like a bare apex (e.g. `old.example.com`), not a URL or wildcard."
  }
}

variable "to_domain" {
  description = "Canonical target domain (apex), e.g. `new.example.com`. The 301 sends every request to `https://<to_domain>/<original-path>?<original-query>`."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.to_domain))
    error_message = "to_domain must look like a bare apex (e.g. `new.example.com`), not a URL."
  }
}

variable "namespace" {
  description = "Kubernetes namespace where the IngressRoute + Middleware land. Defaults to the platform's Traefik namespace so the resources live next to Traefik itself; Traefik watches all namespaces, so any namespace works in practice."
  type        = string
  default     = "ingress-controller"
}

variable "labels" {
  description = "Labels to attach to both emitted manifests. Caller usually passes the platform-wide null-label tag set so the resources are greppable alongside engine-managed cousins."
  type        = map(string)
  default     = {}
}

variable "include_subdomains" {
  description = "Whether the IngressRoute also matches every subdomain of `from_domain` (the `HostRegexp` predicate). True (default) for a whole-zone redirect (apex + `*.from_domain`). Set false for a single-host redirect (e.g. a campaign link host) so only the exact `from_domain` is matched and unrelated subdomains fall through to whatever else claims them."
  type        = bool
  default     = true
}

variable "priority" {
  description = "Traefik route priority for the redirect IngressRoute. Default 2 sits just above the platform-wide `traefik-fallback` (priority 1) but below a default-priority service route, so a whole-zone redirect yields to explicit carve-outs. A single-host redirect that must WIN over an overlapping zone redirect should pass a higher value (e.g. 100) — relying on Traefik's default rule-length priority is unreliable when a long zone-redirect rule competes."
  type        = number
  default     = 2
}
