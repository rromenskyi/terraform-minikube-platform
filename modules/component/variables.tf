variable "name" {
  description = "Component name — used as Deployment/Service name and label selector"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to deploy into"
  type        = string
}

variable "image" {
  description = "Container image (e.g. nginx:alpine)"
  type        = string
}

variable "image_pull_policy" {
  description = <<-EOT
    Kubernetes `imagePullPolicy` for the main container. One of
    `Always` | `IfNotPresent` | `Never`, or `null` to auto-derive from
    the image tag (the default). Auto-derivation mirrors Kubernetes'
    own behavior: a moving tag (`:latest`, or an empty/implicit tag)
    gets `Always` so the kubelet actually refreshes on Pod start; a
    pinned tag (`:1.2.3`, `:main`, etc.) or digest (`@sha256:...`) gets
    `IfNotPresent` to save a registry HEAD per Pod start. Set an
    explicit value to override the heuristic — useful when a
    pinned-looking tag is in fact mutable upstream.
  EOT
  type        = string
  default     = null
  validation {
    condition     = var.image_pull_policy == null ? true : contains(["Always", "IfNotPresent", "Never"], var.image_pull_policy)
    error_message = "image_pull_policy must be null (auto-derive) or one of Always, IfNotPresent, Never."
  }
}

variable "port" {
  description = "Container port exposed by the application"
  type        = number
}

variable "replicas" {
  description = "Desired number of pod replicas"
  type        = number
  default     = 2
}

variable "resources" {
  description = "CPU/memory requests and limits"
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ cpu = string, memory = string })
  })
  default = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { cpu = "200m", memory = "256Mi" }
  }
}

variable "health_path" {
  description = "HTTP path for liveness/readiness probes. Set to null to disable probes."
  type        = string
  default     = "/"
}

variable "storage" {
  description = "Persistent volumes to mount into the container"
  type = list(object({
    mount = string
    size  = string
  }))
  default = []
}

variable "git_sync" {
  description = "Optional git-sync sidecar pulling content from a private repo into an emptyDir mounted at `mount` inside the main container. When set, the deployment gets (a) a one-shot init container that clones the repo before the main container starts, (b) a long-running sidecar that re-pulls on `period_seconds`, and (c) an SSH key Secret mounted at `/etc/git-secret/ssh` for both. Repo content lives in an emptyDir, NOT a PV — pod is free to schedule on any node, content rebuilds from git on every restart. Operator pre-creates the k8s Secret named in `ssh_key_secret_name` with two keys: `ssh-privatekey` (the GitHub deploy key) and `known_hosts` (output of `ssh-keyscan github.com`)."
  type = object({
    repo                = string
    branch              = optional(string, "main")
    period_seconds      = optional(number, 60)
    ssh_key_secret_name = string
    mount               = string
    image               = optional(string, "registry.k8s.io/git-sync/git-sync:v4.4.0")
  })
  default = null
}

variable "db_secret_name" {
  description = "Name of the db-credentials Secret to expose as env vars. Null = no db."
  type        = string
  default     = null
}

variable "db_env_mapping" {
  description = "Map of env var name → secret key for DB credentials. When set, uses individual env vars instead of env_from."
  type        = map(string)
  default     = {}
}

variable "postgres_secret_name" {
  description = "Name of the postgres-credentials Secret to expose as env_from. Null = no postgres. Injects PG_HOST/PG_PORT/PG_DATABASE/PG_USER/PG_PASSWORD/DATABASE_URL."
  type        = string
  default     = null
}

variable "redis_secret_name" {
  description = "Name of the redis-credentials Secret to expose as env_from. Null = no redis. Injects REDIS_HOST/REDIS_PORT/REDIS_USER/REDIS_PASSWORD/REDIS_KEY_PREFIX."
  type        = string
  default     = null
}

variable "ollama_secret_name" {
  description = "Name of the ollama-endpoint Secret to expose as env_from. Null = no ollama. Injects OLLAMA_HOST only (Ollama's API is unauthenticated — any client on the cluster can call it)."
  type        = string
  default     = null
}

variable "oidc_secret_name" {
  description = "Name of the oidc-credentials Secret to expose as env_from. Null = no Zitadel client wired (kind: app components without `oidc.enabled: true`, or any non-app component). Injects AUTH_ZITADEL_ISSUER/AUTH_ZITADEL_ID/AUTH_ZITADEL_SECRET/AUTH_SECRET so a stock @auth/sveltekit Zitadel provider boots with zero in-app config."
  type        = string
  default     = null
}

variable "pod_annotations" {
  description = "Pod-template annotations rendered under `spec.template.metadata.annotations`. Primary use: a `checksum/<name>` entry whose value is a hash of an envFrom-mounted Secret's contents — when the Secret rotates, the annotation flips, and the Deployment rolls out so the pod picks up the new env. K8s does NOT rollout pods on Secret change by itself (envFrom values are read at process start), so anything that drives env from an externally-rotatable Secret (Zitadel OIDC client, etc.) needs this. Caller computes the hash and passes it here."
  type        = map(string)
  default     = {}
}

variable "static_env" {
  description = "Additional static env vars (name → literal value) mounted directly on the container. Use when a component needs a plain env knob that isn't a secret and doesn't come from a shared service."
  type        = map(string)
  default     = {}
}

variable "random_env_secret_name" {
  description = "Name of the Secret holding terraform-generated random values for every env name listed in the component's `env_random:` array. Null when the component has no such entries."
  type        = string
  default     = null
}

variable "volume_base_path" {
  description = "Parent path used verbatim by hostPath PersistentVolumes for this component. Each volume lands at <volume_base_path>/<namespace>/<name>/<slug>/. Must resolve to a real writable directory from the kubelet's point of view (native k3s / --driver=none: any host dir; macOS minikube Docker driver: /minikube-host/Shared/vol)."
  type        = string
  default     = "/data/vol"
}

variable "config_files" {
  description = "Map of file path → content to mount into the container via ConfigMap"
  type        = map(string)
  default     = {}
}

variable "security" {
  description = "Optional pod `securityContext` knobs. `run_as_user` pins the container UID; `fs_group` makes kubelet chown every hostPath volume to that GID at mount time — the latter is how a WordPress image (www-data, UID 33) writes to a host-owned directory without a separate init container."
  type = object({
    run_as_user = optional(number)
    fs_group    = optional(number)
  })
  default = {}
}

variable "sidecars" {
  description = <<-EOT
    Additional containers that run in every Pod of this Deployment,
    keyed by container name. Use for small helper servers the main
    container reaches over loopback (MCP tool servers, local caches,
    token-refresh daemons). Each entry is independent — no Service
    port, no external probes; the main container's probes are enough
    to cover Pod liveness because a sidecar crash restarts the whole
    Pod.

    Per-field notes:
      - `command` / `args`: override the image ENTRYPOINT / CMD. Use
        when the default entrypoint expects capabilities the sidecar
        doesn't need (e.g. open-terminal's wrapper runs iptables setup
        as root; skipping it lets the sidecar run as UID 1000 cleanly).
      - `writable_paths`: every path in this list becomes a per-sidecar
        emptyDir volume mounted at that path. Required when the image
        writes to filesystem paths other than the default `/tmp` (home
        directories, stateful cache dirs) and `readOnlyRootFilesystem`
        is on. Default `["/tmp"]` covers the common case.
      - `env_random`: list of env var names to pull — by `valueFrom.secretKeyRef` —
        from the component-level random-env Secret. The main container
        and any sidecar can list a subset of the component's
        `env_random:` keys; Terraform generates one random value per key
        and injects it wherever it's referenced.
      - `security.run_as_user = 0`: supported for images whose
        entrypoint requires root (rare). The module flips
        `run_as_non_root` to false automatically in that case.
      - `image_pull_policy`: `Always` | `IfNotPresent` | `Never`, or
        leave unset for auto-derivation from the image tag (moving
        tags like `:latest` / implicit → `Always`, anything pinned or
        digest-sealed → `IfNotPresent`). Same rule as the main
        container's top-level `image_pull_policy` knob.
  EOT
  type = map(object({
    image             = string
    port              = optional(number) # informational only; no Service port is opened
    command           = optional(list(string))
    args              = optional(list(string))
    env_static        = optional(map(string), {})
    env_random        = optional(list(string), [])
    writable_paths    = optional(list(string), ["/tmp"])
    image_pull_policy = optional(string, null)
    resources = object({
      requests = object({ cpu = string, memory = string })
      limits   = object({ cpu = string, memory = string })
    })
    security = optional(object({
      run_as_user               = optional(number, 1000)
      read_only_root_filesystem = optional(bool, true)
    }), {})
  }))
  default = {}
}

variable "cluster_role_rules" {
  description = <<-EOT
    Cluster-scoped read access this component needs for the k8s API.
    Non-empty list opts the component into the managed-identity
    pattern: a ServiceAccount named `<component>` in the component's
    namespace + a ClusterRole + ClusterRoleBinding named
    `<namespace>-<component>` carrying the supplied rules. The Pod's
    `service_account_name` is set to the SA so in-cluster requests
    (k8s client libs, kubectl from inside the pod) authenticate
    against the role automatically. Empty list = default SA, no
    cluster RBAC, identical to today's behaviour.
  EOT
  type = list(object({
    api_groups = list(string)
    resources  = list(string)
    verbs      = list(string)
  }))
  default = []
}

variable "env_random_keys" {
  description = <<-EOT
    Keys present in the Secret referenced by `random_env_secret_name`.
    Used to emit one explicit `env` entry per key (with
    `valueFrom.secretKeyRef`) so subsequent `env_static` values can
    refer to them via Kubernetes `$(VAR_NAME)` substitution — which
    does not work with `envFrom`. Safe to leave empty when the
    component has no `env_random:` declaration.
  EOT
  type        = list(string)
  default     = []
}

variable "node_selector" {
  description = <<-EOT
    Node-selector labels the pod must match. Empty map means the
    scheduler can place the pod on any node that satisfies the other
    constraints (resources, taints, affinity). Useful for
    "stateful → optiplex (workload-tier=stateful)" style pinning.
  EOT
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = <<-EOT
    Taints the pod tolerates. Each entry is one toleration block with
    the standard k8s fields. Effects accepted by the API: NoSchedule /
    PreferNoSchedule / NoExecute. `operator` defaults to "Equal" on
    the API side; pass "Exists" to match any value (or omit `value`).
    Empty list = pod cannot land on any tainted node.
  EOT
  type = list(object({
    key                = optional(string)
    operator           = optional(string)
    value              = optional(string)
    effect             = optional(string)
    toleration_seconds = optional(string)
  }))
  default = []
}

variable "affinity" {
  description = <<-EOT
    Pod affinity rules. Mirrors `pod.spec.affinity` — supported
    sub-blocks: `node_affinity`, `pod_affinity`, `pod_anti_affinity`,
    each with `required_during_scheduling_ignored_during_execution`
    and `preferred_during_scheduling_ignored_during_execution`. Empty
    object = no affinity. Type is `any` because the schema is deeply
    nested with optional branches at every level; the dynamic blocks
    below extract via `try()` and only emit fields the caller set.
  EOT
  type        = any
  default     = {}
}
