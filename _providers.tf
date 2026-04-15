provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "kubernetes" {
  host                   = module.platform.cluster_host
  client_certificate     = module.platform.client_certificate
  client_key             = module.platform.client_key
  cluster_ca_certificate = module.platform.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = module.platform.cluster_host
    client_certificate     = module.platform.client_certificate
    client_key             = module.platform.client_key
    cluster_ca_certificate = module.platform.cluster_ca_certificate
  }
}
