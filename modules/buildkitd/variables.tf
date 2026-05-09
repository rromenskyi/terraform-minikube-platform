variable "enabled" {
  description = "Whether to install the buildkitd Pod + Service. False collapses every resource to zero — namespace, kubectl_manifest Deployment, and ClusterIP all disappear, and the `endpoint` output resolves to an empty string."
  type        = bool
  default     = false
}

variable "namespace" {
  description = "Namespace the buildkitd Pod + Service land in. Convention is `arc-buildkitd` (a sibling of the ARC controller's `arc-system` namespace), but operator can override per cluster. Module owns the namespace creation, so the name must not collide with one already managed elsewhere."
  type        = string
  default     = "arc-buildkitd"
}

variable "image_tag" {
  description = "Tag of the upstream `moby/buildkit` image to run. MUST be the rootful variant — the `-rootless` tags need unprivileged userns creation, which Ubuntu 23.10+ blocks at the AppArmor `userns_create` LSM hook by default. Bump as upstream cuts new releases."
  type        = string
  default     = "v0.29.0"
}

variable "host_path" {
  description = "Cluster-node directory the build cache slabs land in (hostPath volume). Survives Pod restarts but is node-pinned — the daemon should be pinned to the same node via `node_selector` so the cache stays warm. Convention is `<host_volume_path>/buildkit-cache`."
  type        = string
  default     = "/data/vol/buildkit-cache"
}

variable "mount_path" {
  description = "In-container path the cache is mounted at. Defaults to the rootful buildkit data directory (`/var/lib/buildkit`). Override only if the operator runs a fork that uses a different layout."
  type        = string
  default     = "/var/lib/buildkit"
}

variable "cpu_request" {
  description = "Container `resources.requests.cpu` for the buildkitd Pod. Buildkit is bursty — the daemon mostly idles between builds and spikes during multi-stage builds. Keep the request low so the Pod isn't blocking scheduler headroom from other workloads."
  type        = string
  default     = "200m"
}

variable "cpu_limit" {
  description = "Container `resources.limits.cpu` for the buildkitd Pod. Cap the spike so a runaway build doesn't starve the rest of the node. `4` (cores) suits a typical multi-stage Dockerfile build."
  type        = string
  default     = "4"
}

variable "memory_request" {
  description = "Container `resources.requests.memory` for the buildkitd Pod. The daemon's resident set is small (~256Mi) when idle, but in-flight builds blow up the working set during layer pack/unpack."
  type        = string
  default     = "512Mi"
}

variable "memory_limit" {
  description = "Container `resources.limits.memory` for the buildkitd Pod. Hit OOM during a build → the build fails with a confusing `failed to copy: cancelled` error rather than a clean OOMKilled, so size for the largest expected build."
  type        = string
  default     = "8Gi"
}

variable "readiness_initial_delay_seconds" {
  description = "`readinessProbe.initialDelaySeconds`. buildkitd boots fast (binary, no JVM), so the default of `5` is more than enough."
  type        = number
  default     = 5
}

variable "readiness_period_seconds" {
  description = "`readinessProbe.periodSeconds`. The buildkit-default of `10` killed Pods mid-build under load — `buildctl debug workers` (the probe command) contends with the active build for the OCI worker lock. `60` keeps the probe out of the build's hot path."
  type        = number
  default     = 60
}

variable "readiness_timeout_seconds" {
  description = "`readinessProbe.timeoutSeconds`. The buildkit-default of `1` is too aggressive when the worker is busy serving a build. `15` is the value that survived a real ARC build cycle on this cluster."
  type        = number
  default     = 15
}

variable "readiness_failure_threshold" {
  description = "`readinessProbe.failureThreshold`. One missed probe shouldn't bin a warm cache; `5` gives the daemon room to ride out a transient lock-contention burst."
  type        = number
  default     = 5
}

variable "node_selector" {
  description = "Node selector for the buildkitd Pod. Strongly recommended in any multi-node cluster — the hostPath cache is node-pinned and the daemon needs to land on the same node every time, otherwise a Pod reschedule starts with a cold cache. Empty (default) lets the scheduler pick freely."
  type        = map(string)
  default     = {}
}

variable "tolerations" {
  description = "Tolerations for the buildkitd Pod. Standard k8s toleration shape — set this when the chosen node carries a NoSchedule taint that the buildkitd Pod needs to bypass."
  type = list(object({
    key      = optional(string)
    operator = optional(string, "Exists")
    value    = optional(string)
    effect   = optional(string)
  }))
  default = []
}
