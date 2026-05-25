# variables.tf
# Input variables for the DNS module.

variable "project_id" {
  description = "The GCP project ID that owns the managed zone"
  type        = string
}

variable "zone_name" {
  description = "Name of the existing Cloud DNS managed zone to reference"
  type        = string
  default     = "platform-zone"
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
