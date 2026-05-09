terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}


# ── Pod placement primitives ─────────────────────────────────────────────────
# Three orthogonal scheduler hints, all empty by default so existing
# components see no behaviour change. Map directly onto the matching
# fields of `pod.spec` (k8s API v1):
#   * node_selector — simplest pinning ("this label = this value")
#   * tolerations   — opt-in to scheduling on tainted nodes
#   * affinity      — richer node / pod (anti-)affinity expressions
# Per-component yaml exposes all three under the same names; the
# `modules/project` consumer pipes them through unchanged.


# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  # Map slug → volume spec. Slug is the PV/PVC name suffix and k8s volume name.
  volumes = {
    for v in var.storage :
    replace(trimprefix(v.mount, "/"), "/", "-") => v
  }

  # Flatten every (sidecar, writable_path) pair into a single map keyed by
  # a stable volume/mount name. One emptyDir per pair so two sidecars (or
  # two paths within one sidecar) cannot clobber each other's scratch
  # state. The slug is cleaned so characters illegal in a Kubernetes
  # volume name (`/`) become dashes.
  sidecar_writable_volumes = merge([
    for sc_name, sc in var.sidecars : {
      for path in sc.writable_paths :
      "sidecar-${sc_name}-${replace(trimprefix(path, "/"), "/", "-")}" => {
        sidecar    = sc_name
        mount_path = path
      }
    }
  ]...)

  # Main container imagePullPolicy, resolved from the explicit var when
  # the caller set one, otherwise derived from the image reference:
  #   * `foo:latest`, `foo` (no tag = implicit :latest)     → Always
  #   * `foo@sha256:...` (digest pin) or any other tag      → IfNotPresent
  # The regex captures the tag after the LAST `:` as long as it's not
  # followed by `/` (registry hostname port like `ghcr.io:443/...` won't
  # accidentally match) and not inside an `@`-separated digest.
  rbac_instances = length(var.cluster_role_rules) > 0 ? toset(["enabled"]) : toset([])

  effective_image_pull_policy = (
    var.image_pull_policy != null
    ? var.image_pull_policy
    : local._derived_pull_policy_for_image
  )
  _derived_pull_policy_for_image = local._tag_of_main_image == "" || local._tag_of_main_image == "latest" ? "Always" : "IfNotPresent"
  _tag_of_main_image = (
    strcontains(var.image, "@")
    ? "pinned-digest"
    : try(regex(":([^/@]+)$", var.image)[0], "")
  )

  # Same derivation for every sidecar, keyed by sidecar name.
  sidecar_effective_pull_policy = {
    for name, sc in var.sidecars :
    name => (
      sc.image_pull_policy != null
      ? sc.image_pull_policy
      : (
        strcontains(sc.image, "@")
        ? "IfNotPresent"
        : (
          local.sidecar_tags[name] == "" || local.sidecar_tags[name] == "latest"
          ? "Always"
          : "IfNotPresent"
        )
      )
    )
  }
  sidecar_tags = {
    for name, sc in var.sidecars :
    name => (
      strcontains(sc.image, "@")
      ? "pinned-digest"
      : try(regex(":([^/@]+)$", sc.image)[0], "")
    )
  }
}

# ── Persistent Volumes ────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_v1" "this" {
  for_each = local.volumes

  metadata {
    name = "${var.namespace}-${var.name}-${each.key}"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "project-namespace"            = var.namespace
      "component"                    = var.name
    }
  }

  spec {
    capacity = {
      storage = each.value.size
    }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "standard"

    persistent_volume_source {
      host_path {
        # Resolves to e.g.
        #   macOS minikube: /minikube-host/Shared/vol/{namespace}/{component}/{slug}/
        #   native k3s:     /data/vol/{namespace}/{component}/{slug}/
        path = "${var.volume_base_path}/${var.namespace}/${var.name}/${each.key}"
        type = "DirectoryOrCreate"
      }
    }
  }
}

# ── Persistent Volume Claims ──────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim_v1" "this" {
  for_each = local.volumes

  metadata {
    name      = "${var.name}-${each.key}"
    namespace = var.namespace
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "standard"
    volume_name        = kubernetes_persistent_volume_v1.this[each.key].metadata[0].name

    resources {
      requests = {
        storage = each.value.size
      }
    }
  }
}

# ── Config Files (ConfigMap) ──────────────────────────────────────────────────

resource "kubernetes_config_map_v1" "files" {
  count = length(var.config_files) > 0 ? 1 : 0

  metadata {
    name      = "${var.name}-config"
    namespace = var.namespace
    labels    = { app = var.name }
  }

  data = {
    for path, content in var.config_files :
    replace(trimprefix(path, "/"), "/", "--") => content
  }
}

# ── Cluster RBAC (managed-identity pattern) ───────────────────────────────────
#
# When `var.cluster_role_rules` is non-empty, emit a SA in the
# component's namespace + a cluster-scoped Role + Binding so the
# Pod's in-cluster k8s API requests authenticate as the component
# itself. Names: SA = `<component>`; ClusterRole + Binding =
# `<namespace>-<component>` so they don't collide cluster-wide.

resource "kubernetes_service_account_v1" "this" {
  for_each = local.rbac_instances

  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }
}

resource "kubernetes_cluster_role_v1" "this" {
  for_each = local.rbac_instances

  metadata {
    name   = "${var.namespace}-${var.name}"
    labels = { app = var.name }
  }

  dynamic "rule" {
    for_each = var.cluster_role_rules
    content {
      api_groups = rule.value.api_groups
      resources  = rule.value.resources
      verbs      = rule.value.verbs
    }
  }
}

resource "kubernetes_cluster_role_binding_v1" "this" {
  for_each = local.rbac_instances

  metadata {
    name   = "${var.namespace}-${var.name}"
    labels = { app = var.name }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.this["enabled"].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.this["enabled"].metadata[0].name
    namespace = var.namespace
  }
}

# ── Deployment ────────────────────────────────────────────────────────────────

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = var.name }
    }

    template {
      metadata {
        labels      = { app = var.name }
        annotations = var.pod_annotations
      }

      spec {
        # Custom SA when cluster_role_rules is non-empty; default SA
        # otherwise. K8s defaults to "default" SA in the namespace —
        # leaving service_account_name unset preserves that.
        service_account_name = length(var.cluster_role_rules) > 0 ? kubernetes_service_account_v1.this["enabled"].metadata[0].name : null

        # Pod placement: node_selector, tolerations, affinity. All
        # default to empty so this block is a no-op for existing
        # components. Wired identically into the StatefulSet path
        # below (when one is added) and into shared service modules.
        node_selector = length(var.node_selector) > 0 ? var.node_selector : null

        dynamic "toleration" {
          for_each = var.tolerations
          content {
            key                = toleration.value.key
            operator           = toleration.value.operator
            value              = toleration.value.value
            effect             = toleration.value.effect
            toleration_seconds = toleration.value.toleration_seconds
          }
        }

        dynamic "affinity" {
          for_each = length(keys(var.affinity)) > 0 ? [var.affinity] : []
          content {
            dynamic "node_affinity" {
              for_each = try(affinity.value.node_affinity, null) != null ? [affinity.value.node_affinity] : []
              content {
                dynamic "required_during_scheduling_ignored_during_execution" {
                  for_each = try(node_affinity.value.required_during_scheduling_ignored_during_execution, null) != null ? [node_affinity.value.required_during_scheduling_ignored_during_execution] : []
                  content {
                    dynamic "node_selector_term" {
                      for_each = try(required_during_scheduling_ignored_during_execution.value.node_selector_terms, [])
                      content {
                        dynamic "match_expressions" {
                          for_each = try(node_selector_term.value.match_expressions, [])
                          content {
                            key      = match_expressions.value.key
                            operator = match_expressions.value.operator
                            values   = try(match_expressions.value.values, null)
                          }
                        }
                      }
                    }
                  }
                }
                dynamic "preferred_during_scheduling_ignored_during_execution" {
                  for_each = try(node_affinity.value.preferred_during_scheduling_ignored_during_execution, [])
                  content {
                    weight = preferred_during_scheduling_ignored_during_execution.value.weight
                    preference {
                      dynamic "match_expressions" {
                        for_each = try(preferred_during_scheduling_ignored_during_execution.value.preference.match_expressions, [])
                        content {
                          key      = match_expressions.value.key
                          operator = match_expressions.value.operator
                          values   = try(match_expressions.value.values, null)
                        }
                      }
                    }
                  }
                }
              }
            }
            dynamic "pod_affinity" {
              for_each = try(affinity.value.pod_affinity, null) != null ? [affinity.value.pod_affinity] : []
              content {
                dynamic "required_during_scheduling_ignored_during_execution" {
                  for_each = try(pod_affinity.value.required_during_scheduling_ignored_during_execution, [])
                  content {
                    topology_key = required_during_scheduling_ignored_during_execution.value.topology_key
                    namespaces   = try(required_during_scheduling_ignored_during_execution.value.namespaces, null)
                    dynamic "label_selector" {
                      for_each = try(required_during_scheduling_ignored_during_execution.value.label_selector, null) != null ? [required_during_scheduling_ignored_during_execution.value.label_selector] : []
                      content {
                        match_labels = try(label_selector.value.match_labels, null)
                        dynamic "match_expressions" {
                          for_each = try(label_selector.value.match_expressions, [])
                          content {
                            key      = match_expressions.value.key
                            operator = match_expressions.value.operator
                            values   = try(match_expressions.value.values, null)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            dynamic "pod_anti_affinity" {
              for_each = try(affinity.value.pod_anti_affinity, null) != null ? [affinity.value.pod_anti_affinity] : []
              content {
                dynamic "required_during_scheduling_ignored_during_execution" {
                  for_each = try(pod_anti_affinity.value.required_during_scheduling_ignored_during_execution, [])
                  content {
                    topology_key = required_during_scheduling_ignored_during_execution.value.topology_key
                    namespaces   = try(required_during_scheduling_ignored_during_execution.value.namespaces, null)
                    dynamic "label_selector" {
                      for_each = try(required_during_scheduling_ignored_during_execution.value.label_selector, null) != null ? [required_during_scheduling_ignored_during_execution.value.label_selector] : []
                      content {
                        match_labels = try(label_selector.value.match_labels, null)
                        dynamic "match_expressions" {
                          for_each = try(label_selector.value.match_expressions, [])
                          content {
                            key      = match_expressions.value.key
                            operator = match_expressions.value.operator
                            values   = try(match_expressions.value.values, null)
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        dynamic "security_context" {
          for_each = (
            try(var.security.run_as_user, null) != null
            || try(var.security.fs_group, null) != null
            || var.git_sync != null
          ) ? [1] : []
          content {
            run_as_user = try(var.security.run_as_user, null)
            # git-sync sidecar / init container run as uid 65533 and
            # mount the SSH-key Secret with default_mode = 0400. Without
            # an fsGroup the files end up owned by root:root mode 0400,
            # uid 65533 cannot read them, and ssh silently treats the
            # known_hosts file as empty → "No ED25519 host key is known
            # for github.com" host-key verification failure. Default to
            # 65533 when git_sync is enabled and the operator did not
            # set fs_group explicitly.
            fs_group = coalesce(
              try(var.security.fs_group, null),
              var.git_sync != null ? 65533 : null,
            )
          }
        }

        # git-sync one-shot clone before the main container starts.
        # Without this, the main container can race the sidecar and
        # see an empty mount on first boot. `--one-time` exits 0
        # after the initial sync, so the init phase converges
        # quickly. Same image + key shape as the long-running
        # sidecar below — keep them in sync.
        dynamic "init_container" {
          for_each = var.git_sync == null ? [] : [var.git_sync]
          content {
            name              = "git-sync-init"
            image             = init_container.value.image
            image_pull_policy = "IfNotPresent"

            args = [
              "--repo=${init_container.value.repo}",
              "--ref=${init_container.value.branch}",
              "--root=/git",
              "--link=current",
              "--depth=1",
              "--one-time",
              "--ssh-key-file=/etc/git-secret/ssh-privatekey",
              "--ssh-known-hosts-file=/etc/git-secret/known_hosts",
            ]

            resources {
              requests = { cpu = "10m", memory = "32Mi" }
              limits   = { cpu = "200m", memory = "128Mi" }
            }

            security_context {
              run_as_user                = 65533
              run_as_non_root            = true
              allow_privilege_escalation = false
              capabilities {
                drop = ["ALL"]
              }
            }

            volume_mount {
              name       = "git-content"
              mount_path = "/git"
            }
            volume_mount {
              name       = "git-secret"
              mount_path = "/etc/git-secret"
              read_only  = true
            }
          }
        }

        # hostPath volumes ignore the pod-level `fsGroup` — the kubelet
        # refuses to recursively chown something on the host filesystem
        # it didn't create. Without this init container, a non-root main
        # container (e.g. WordPress's www-data, UID 33) fails on first
        # start with `mkdir: Permission denied` trying to seed
        # `/var/www/html/wp-content` from the image. Run a one-shot root
        # container that chowns every mounted volume to the configured
        # UID/GID, then the main container can read/write normally.
        dynamic "init_container" {
          for_each = (
            try(var.security.fs_group, null) != null
            && length(local.volumes) > 0
          ) ? [1] : []
          content {
            name  = "chown-volumes"
            image = "busybox:stable-musl"

            security_context {
              run_as_user = 0
            }

            # Minimal resources — the init container runs once per pod
            # start, for milliseconds, and only issues a chown. Explicit
            # values are required because tenant namespaces carry a
            # LimitRange that rejects any container missing them.
            resources {
              requests = { cpu = "10m", memory = "16Mi" }
              limits   = { cpu = "50m", memory = "32Mi" }
            }

            command = ["sh", "-c", join(" && ", [
              for k, v in local.volumes :
              "chown -R ${try(var.security.run_as_user, 0)}:${var.security.fs_group} ${v.mount}"
            ])]

            dynamic "volume_mount" {
              for_each = local.volumes
              content {
                name       = volume_mount.key
                mount_path = volume_mount.value.mount
              }
            }
          }
        }

        container {
          name              = var.name
          image             = var.image
          image_pull_policy = local.effective_image_pull_policy

          port {
            container_port = var.port
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }

          # DB credentials: mapped env vars (e.g. WORDPRESS_DB_HOST → secret key DB_HOST)
          dynamic "env" {
            for_each = var.db_secret_name != null && length(var.db_env_mapping) > 0 ? var.db_env_mapping : {}
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name = var.db_secret_name
                  key  = env.value
                }
              }
            }
          }

          # DB credentials injected as-is from Secret (when no mapping provided)
          dynamic "env_from" {
            for_each = var.db_secret_name != null && length(var.db_env_mapping) == 0 ? [var.db_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # PostgreSQL credentials (PG_HOST/PORT/DATABASE/USER/PASSWORD/DATABASE_URL)
          dynamic "env_from" {
            for_each = var.postgres_secret_name != null ? [var.postgres_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # Redis credentials (REDIS_HOST/PORT/USER/PASSWORD/KEY_PREFIX)
          dynamic "env_from" {
            for_each = var.redis_secret_name != null ? [var.redis_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # Ollama endpoint (OLLAMA_HOST)
          dynamic "env_from" {
            for_each = var.ollama_secret_name != null ? [var.ollama_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # OIDC client credentials (AUTH_ZITADEL_*, AUTH_SECRET) —
          # populated by modules/zitadel-app for `kind: app` components
          # whose YAML opted into `oidc.enabled: true`.
          dynamic "env_from" {
            for_each = var.oidc_secret_name != null ? [var.oidc_secret_name] : []
            content {
              secret_ref {
                name = env_from.value
              }
            }
          }

          # Random-value env vars — one key per entry in the component's
          # `env_random:` list (e.g. WEBUI_SECRET_KEY). Values persist in
          # terraform state across applies. Emitted as explicit `env`
          # entries with `valueFrom.secretKeyRef` (not `env_from`) so
          # later `env_static` values can reference them via the
          # Kubernetes `$(VAR_NAME)` expansion — which only works between
          # explicit `env` list entries, not for `envFrom`-sourced vars.
          dynamic "env" {
            for_each = var.random_env_secret_name != null ? toset(var.env_random_keys) : toset([])
            content {
              name = env.value
              value_from {
                secret_key_ref {
                  name = var.random_env_secret_name
                  key  = env.value
                }
              }
            }
          }

          # Arbitrary static env vars supplied by the component's yaml.
          # Appears *after* the random_env block above so values can
          # reference random keys via `$(VAR_NAME)`.
          dynamic "env" {
            for_each = var.static_env
            content {
              name  = env.key
              value = env.value
            }
          }

          # Health probes — disabled when health_path is null (e.g. WordPress setup flow)
          dynamic "liveness_probe" {
            for_each = var.health_path != null ? [1] : []
            content {
              http_get {
                path = var.health_path
                port = var.port
              }
              initial_delay_seconds = 10
              period_seconds        = 10
            }
          }

          # Covers slow-boot containers (Open WebUI does SQLite migrations on
          # first start, ~60–90s). Until startup_probe passes, kubelet
          # skips readiness_probe and liveness_probe, so slow boots don't
          # trigger a restart loop. 30 × 10s = 5 minutes budget.
          dynamic "startup_probe" {
            for_each = var.health_path != null ? [1] : []
            content {
              http_get {
                path = var.health_path
                port = var.port
              }
              period_seconds    = 10
              failure_threshold = 30
              timeout_seconds   = 5
            }
          }

          dynamic "readiness_probe" {
            for_each = var.health_path != null ? [1] : []
            content {
              http_get {
                path = var.health_path
                port = var.port
              }
              initial_delay_seconds = 5
              period_seconds        = 5
            }
          }

          dynamic "volume_mount" {
            for_each = local.volumes
            content {
              name       = volume_mount.key
              mount_path = volume_mount.value.mount
            }
          }

          dynamic "volume_mount" {
            for_each = var.config_files
            content {
              name       = "config-files"
              mount_path = volume_mount.key
              sub_path   = replace(trimprefix(volume_mount.key, "/"), "/", "--")
              read_only  = true
            }
          }

          # git-sync content. emptyDir is shared with the
          # `git-sync-init` and `git-sync` containers; they write
          # the worktree to `/git/<sha>` and a symlink at
          # `/git/current` always points at the latest. Mounting
          # the SAME emptyDir at `var.git_sync.mount` here with
          # `subPath = "current"` resolves the symlink at mount
          # time, so the main container sees the live content
          # under its expected path.
          dynamic "volume_mount" {
            for_each = var.git_sync == null ? [] : [var.git_sync]
            content {
              name       = "git-content"
              mount_path = volume_mount.value.mount
              sub_path   = "current"
              read_only  = true
            }
          }
        }

        # git-sync long-running sidecar — periodic re-pull every
        # `period_seconds`. Same image + key shape as the init
        # container above. Atomic worktree swap via the `current`
        # symlink: the main container mounts `subPath = "current"`,
        # so a swap propagates immediately on the next syscall.
        dynamic "container" {
          for_each = var.git_sync == null ? [] : [var.git_sync]
          content {
            name              = "git-sync"
            image             = container.value.image
            image_pull_policy = "IfNotPresent"

            args = [
              "--repo=${container.value.repo}",
              "--ref=${container.value.branch}",
              "--root=/git",
              "--link=current",
              "--depth=1",
              "--period=${container.value.period_seconds}s",
              "--ssh-key-file=/etc/git-secret/ssh-privatekey",
              "--ssh-known-hosts-file=/etc/git-secret/known_hosts",
            ]

            resources {
              requests = { cpu = "10m", memory = "32Mi" }
              limits   = { cpu = "200m", memory = "128Mi" }
            }

            security_context {
              run_as_user                = 65533
              run_as_non_root            = true
              allow_privilege_escalation = false
              capabilities {
                drop = ["ALL"]
              }
            }

            volume_mount {
              name       = "git-content"
              mount_path = "/git"
            }
            volume_mount {
              name       = "git-secret"
              mount_path = "/etc/git-secret"
              read_only  = true
            }
          }
        }

        # Helper containers co-located with the main one. Declared in the
        # component yaml via `sidecars:`; see the variable's description.
        # Intentionally minimal: no probes (main container's probes cover
        # Pod liveness) and no Service port.
        dynamic "container" {
          for_each = var.sidecars
          content {
            name              = container.key
            image             = container.value.image
            image_pull_policy = local.sidecar_effective_pull_policy[container.key]
            command           = container.value.command
            args              = container.value.args

            resources {
              requests = container.value.resources.requests
              limits   = container.value.resources.limits
            }

            # Random-value env vars shared with the main container — each
            # listed key pulls `valueFrom.secretKeyRef` from the
            # component's random-env Secret (same one the main container
            # reads). Emitted before `env_static` so `$(VAR_NAME)`
            # substitution in static values resolves.
            dynamic "env" {
              for_each = var.random_env_secret_name != null ? toset(container.value.env_random) : toset([])
              content {
                name = env.value
                value_from {
                  secret_key_ref {
                    name = var.random_env_secret_name
                    key  = env.value
                  }
                }
              }
            }

            dynamic "env" {
              for_each = container.value.env_static
              content {
                name  = env.key
                value = env.value
              }
            }

            security_context {
              allow_privilege_escalation = false
              read_only_root_filesystem  = try(container.value.security.read_only_root_filesystem, true)
              # Running as root is rare but legitimate for images whose
              # entrypoint needs it (iptables setup, chown bind mounts).
              # `run_as_non_root` then has to be false to stay consistent
              # with `run_as_user = 0` — the kubelet refuses the mismatch.
              run_as_non_root = try(container.value.security.run_as_user, 1000) != 0
              run_as_user     = try(container.value.security.run_as_user, 1000)
              capabilities {
                drop = ["ALL"]
              }
            }

            # Every path in the sidecar's `writable_paths` list gets its
            # own emptyDir. Default is just /tmp, but images that write
            # to e.g. /home/user (open-terminal) list the extra paths.
            dynamic "volume_mount" {
              for_each = {
                for k, v in local.sidecar_writable_volumes :
                k => v if v.sidecar == container.key
              }
              content {
                name       = volume_mount.key
                mount_path = volume_mount.value.mount_path
              }
            }
          }
        }

        dynamic "volume" {
          for_each = local.volumes
          content {
            name = volume.key
            persistent_volume_claim {
              claim_name = kubernetes_persistent_volume_claim_v1.this[volume.key].metadata[0].name
            }
          }
        }

        dynamic "volume" {
          for_each = length(var.config_files) > 0 ? [1] : []
          content {
            name = "config-files"
            config_map {
              name = kubernetes_config_map_v1.files[0].metadata[0].name
            }
          }
        }

        # git-sync emptyDir shared between init container, sidecar,
        # and the main container's mount.
        dynamic "volume" {
          for_each = var.git_sync == null ? [] : [1]
          content {
            name = "git-content"
            empty_dir {}
          }
        }

        # SSH deploy key + known_hosts. Operator pre-creates the
        # Secret; the module just projects it read-only into both
        # git-sync containers.
        dynamic "volume" {
          for_each = var.git_sync == null ? [] : [var.git_sync]
          content {
            name = "git-secret"
            secret {
              secret_name  = volume.value.ssh_key_secret_name
              default_mode = "0400"
            }
          }
        }

        # One emptyDir per (sidecar, writable_path) pair — see
        # `local.sidecar_writable_volumes`. Two sidecars can't clobber
        # each other's scratch state, and a readOnlyRootFilesystem
        # sidecar always has somewhere to write for the paths it
        # explicitly declared.
        dynamic "volume" {
          for_each = local.sidecar_writable_volumes
          content {
            name = volume.key
            empty_dir {}
          }
        }
      }
    }
  }
}

# ── Service ───────────────────────────────────────────────────────────────────

resource "kubernetes_service_v1" "this" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }

  spec {
    selector = { app = var.name }

    port {
      port        = var.port
      target_port = var.port
    }
  }
}
