# Local backend (remote S3 on Backblaze B2 returns InvalidAccessKeyId)
# Use remote backend only when you have valid credentials
terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}
