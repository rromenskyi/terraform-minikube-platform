# Platform Architecture

## Current Model

- `main.tf` bootstraps the shared platform through the external `terraform-minikube-k8s` module.
- `config/domains/*.yaml` defines application projects: domain, namespace, limits, and component list.
- `config/components/*.yaml` stores reusable component defaults.
- `config/limits/default.yaml` defines the default namespace quota profile.
- `_backend.tf` keeps remote state configuration in the root stack only.
- Terraform creates the Minikube cluster through the module; manual `minikube start` is not the standard workflow.

## Assembly Flow

- `locals.tf` loads YAML from `config/domains`, `config/components`, and `config/limits`.
- `modules/project` creates a namespace and `ResourceQuota` for each domain.
- `modules/project` normalizes a component by merging built-in defaults, `config/components` defaults, and per-domain overrides.
- `modules/component` creates the `Deployment`, `Service`, and `IngressRoute` resources.

## Current Limitations

- Cloudflare DNS and tunnel ingress are still defined statically in `cloudflare.tf` instead of being generated from `config/domains`.
- Domain aliases and zone-specific settings are not yet modeled in code.

Today, adding a new project means creating a new file in `config/domains` and reusing existing component definitions from `config/components`.
