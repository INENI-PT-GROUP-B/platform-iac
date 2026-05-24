# variables.tf
# Input variables for the DNS module.

variable "project_id" {
  description = "The GCP project ID that owns the managed zone"
  type        = string
}

variable "zone_name" {
  description = "Name of the Cloud DNS managed zone"
  type        = string
  default     = "platform-zone"
}

variable "dns_name" {
  description = "Fully-qualified DNS name of the zone, with trailing dot"
  type        = string
  default     = "fhuebung.lol."
}

variable "zone_description" {
  description = "Human-readable description attached to the managed zone"
  type        = string
  default     = "Public zone for the platform domain, managed by Terraform"
}

variable "dns_admin_service_accounts" {
  description = <<-EOT
    Service-account emails granted roles/dns.admin scoped to the zone
    (ExternalDNS, cert-manager). Wired from the IAM module by the root module;
    empty until then, in which case no IAM bindings are created.
  EOT
  type        = list(string)
  default     = []
}
