terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    # minikube and k3s provider requirements are declared by the child modules
    # (`terraform-minikube-k8s` / `terraform-k3s-k8s`). The root stack does not
    # reference either provider directly.
  }
}
