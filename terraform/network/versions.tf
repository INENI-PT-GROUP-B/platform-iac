# versions.tf
# Provider and Terraform version requirements for the network module.
# The provider configuration itself is inherited from the root module.

terraform {
  required_version = ">= 1.15.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}
