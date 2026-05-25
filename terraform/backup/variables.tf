# variables.tf
# Input variables for the backup module: the shared CloudNativePG backup bucket
# and the IAM that lets Crossplane manage per-tenant write access on it.

variable "project_id" {
  description = "The GCP project ID that owns the backup bucket"
  type        = string
}

variable "region" {
  description = "Location for the backup bucket"
  type        = string
  default     = "europe-west1"
}

variable "crossplane_provider_gcp_sa_email" {
  description = "Email of the Crossplane provider-gcp Google Service Account, granted bucket-scoped storage.admin so the per-tenant Composition can add prefix-scoped write bindings"
  type        = string
}
