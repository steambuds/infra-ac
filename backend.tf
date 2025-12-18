# Backend configuration for storing Terraform state in GCS
# Note: Backend blocks cannot use variables (Terraform limitation)
# The bucket name will be configured during 'terraform init'

terraform {
  backend "gcs" {
    prefix = "terraform/state"
    # bucket is configured via backend-config.tfbackend or -backend-config flag
  }
}
