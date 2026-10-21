# samba

Samba file server for the LAN on a replicated volume
([ServerContainers](https://github.com/ServerContainers/samba) image,
configured by environment variables, macOS `fruit` defaults built in).

- **Storage:** one volume from `storage_class`; each share is a directory
  `/shares/<share>`. With a 2-copy class (e.g. LINSTOR `placement_count: 2`)
  the server survives one storage node being down: the pod restarts on the
  other node with the same volume.
- **Address:** a fixed LAN address from a MetalLB L2 pool (`address_pool`,
  `load_balancer_ip`). `externalTrafficPolicy: Local` keeps the clients'
  addresses, so `hosts allow` (`allowed_networks`) sees real LAN addresses;
  no NodePorts are allocated, so SMB is not reachable on other node
  addresses. The pool must announce from the `node_hostnames` nodes.
- **Accounts:** `users` (uid per account); passwords in Vault at
  `vault_path`, one key per username, synced by Vault Secrets Operator. A
  password change restarts the server.
- **Failover:** `failover_seconds` (default 30) replaces Kubernetes' 300 s
  before a pod on a not-ready/unreachable node is moved.
- **Seed:** `seed = { node, host_path }` mirrors an existing directory tree
  (`<host_path>/<share>`) into the volume with `rsync -aHAX --delete` on every
  start while set (owners, ACLs, extended attributes = macOS metadata, hard
  links). First run copies everything, later runs only the changes. Make the
  old shares read-only before the last run and clear `seed` before writing to
  the new server.

Extended attributes: Samba keeps small macOS metadata streams in xattrs. ext4
limits all xattrs of one file to about one block (4 KiB); check existing data
before seeding onto an ext4 class.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | ~> 1.14 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | ~> 2.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | git::https://github.com/rromenskyi/terraform-null-label.git | v0.1.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [kubectl_manifest.accounts_vault](https://registry.terraform.io/providers/gavinbunney/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_deployment_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/deployment_v1) | resource |
| [kubernetes_namespace_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.data](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_claim_v1.seed](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_claim_v1) | resource |
| [kubernetes_persistent_volume_v1.seed](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/persistent_volume_v1) | resource |
| [kubernetes_service_account_v1.vso_proxy](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_account_v1) | resource |
| [kubernetes_service_v1.this](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/service_v1) | resource |
| [terraform_data.checks](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_address_pool"></a> [address\_pool](#input\_address\_pool) | MetalLB address pool `load_balancer_ip` comes from. | `string` | `""` | no |
| <a name="input_allowed_networks"></a> [allowed\_networks](#input\_allowed\_networks) | Client networks Samba accepts (`hosts allow`); everything else is denied. The Service keeps client source addresses, so these are the real LAN addresses. | `list(string)` | `[]` | no |
| <a name="input_context"></a> [context](#input\_context) | Serialised parent context from `terraform-null-label`. Caller passes `module.platform_label.context` from the root stack so this module chains its own label off the platform-wide context. Default `null` means the module produces a label with no inherited context. | `string` | `null` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to deploy the Samba file server. False collapses every resource. | `bool` | `false` | no |
| <a name="input_failover_seconds"></a> [failover\_seconds](#input\_failover\_seconds) | How long the pod stays bound to a node that is not ready or unreachable before Kubernetes moves it (tolerationSeconds). Default 300 in Kubernetes; lower = faster failover after a node crash. | `number` | `30` | no |
| <a name="input_image"></a> [image](#input\_image) | Samba image (ServerContainers, configured by environment variables; macOS `fruit` defaults built in). Pin a tag or digest. | `string` | `"ghcr.io/servercontainers/samba:a3.24.2-s4.23.8-r0"` | no |
| <a name="input_load_balancer_ip"></a> [load\_balancer\_ip](#input\_load\_balancer\_ip) | Fixed LAN address of the file server (a MetalLB L2 address). Clients mount `smb://<address>/<share>`. | `string` | `""` | no |
| <a name="input_namespace"></a> [namespace](#input\_namespace) | Namespace of the file server. | `string` | `"nas"` | no |
| <a name="input_node_hostnames"></a> [node\_hostnames](#input\_node\_hostnames) | Nodes the file server may run on (`kubernetes.io/hostname`), a required node affinity. With a 2-copy volume, list the nodes holding the copies. The address pool must announce from the same nodes (the Service keeps the clients' source address, `externalTrafficPolicy: Local`). | `list(string)` | `[]` | no |
| <a name="input_resources"></a> [resources](#input\_resources) | Resources of the Samba container. | <pre>object({<br/>    requests = map(string)<br/>    limits   = map(string)<br/>  })</pre> | <pre>{<br/>  "limits": {<br/>    "cpu": "2",<br/>    "memory": "2Gi"<br/>  },<br/>  "requests": {<br/>    "cpu": "100m",<br/>    "memory": "256Mi"<br/>  }<br/>}</pre> | no |
| <a name="input_seed"></a> [seed](#input\_seed) | Copy existing data in before the server starts: a directory on one node<br/>whose subdirectories are the shares (`<host_path>/<share>`). An init<br/>container runs `rsync -aHAX --delete` (keeps owners, ACLs, extended<br/>attributes = macOS metadata, hard links) from it into the volume on every<br/>start while this is set, and the pod is pinned to `node` meanwhile. The<br/>first run copies everything; a restart only copies the changes. While set,<br/>the volume mirrors the old data: make the old shares read-only before the<br/>last run, and clear this (null) before writing to the new server. | <pre>object({<br/>    node      = string<br/>    host_path = string<br/>  })</pre> | `null` | no |
| <a name="input_seed_image"></a> [seed\_image](#input\_seed\_image) | Image with rsync for the seed init container. | `string` | `"instrumentisto/rsync-ssh:alpine3.23-r3"` | no |
| <a name="input_shares"></a> [shares](#input\_shares) | Shares, each a directory `/shares/<name>` on the volume: name, read\_only (default false), valid\_users (default: every account). | <pre>list(object({<br/>    name        = string<br/>    read_only   = optional(bool, false)<br/>    valid_users = optional(list(string), [])<br/>  }))</pre> | `[]` | no |
| <a name="input_size"></a> [size](#input\_size) | Size of the shares' volume. Can be raised later (online expansion, if the StorageClass allows it). | `string` | `"100Gi"` | no |
| <a name="input_storage_class"></a> [storage\_class](#input\_storage\_class) | StorageClass of the shares' volume. Use a replicated class (e.g. a 2-copy LINSTOR class) so the file server survives one storage node being down: the pod then starts on another node with the volume. | `string` | `""` | no |
| <a name="input_users"></a> [users](#input\_users) | Samba accounts: username => { uid }. The uid owns the files (match the owner of migrated data). Passwords come from Vault (`vault_path`, one key per username). | <pre>map(object({<br/>    uid = number<br/>  }))</pre> | `{}` | no |
| <a name="input_vault_path"></a> [vault\_path](#input\_vault\_path) | KV-v2 path under the `secret` mount (e.g. `platform/samba/accounts`) holding one key per username in `users`, value = that user's password. Synced into the namespace by Vault Secrets Operator; a password change restarts the server. | `string` | `"platform/samba/accounts"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_address"></a> [address](#output\_address) | Fixed LAN address of the file server — clients mount `smb://<address>/<share>`. Empty when disabled. |
| <a name="output_namespace"></a> [namespace](#output\_namespace) | Namespace the file server lands in. Empty when the module is disabled. |
<!-- END_TF_DOCS -->
