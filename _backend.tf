# Remote S3 backend on Backblaze B2 (S3-compatible)
# Credentials loaded from .env
terraform {
  backend "s3" {
    bucket = "tfstate-unique"
    key    = "dev/terraform-minikube.tfstate"
    region = "us-east-1"

    endpoints = {
      s3 = "https://s3.us-east-005.backblazeb2.com"
    }

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}
