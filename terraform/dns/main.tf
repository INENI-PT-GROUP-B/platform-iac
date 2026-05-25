# main.tf
# Reference to the persistent public Cloud DNS managed zone for the platform
# domain, plus a zone-scoped roles/dns.admin binding for the workloads that
# manage records. The provider configuration is inherited from the root module.

# The managed zone is persistent infrastructure: created and delegated once and
# never destroyed on teardown, in the same class as the Terraform state bucket
# and Google Secret Manager. bootstrap.sh creates it create-if-absent before
# `terraform apply`, so Terraform references it via a data source rather than
# owning its lifecycle. This keeps the registrar (Porkbun) nameservers stable
# and out of the bootstrap path — no NS update ever runs during a bootstrap.
# See architecture-decisions.md (DNS/TLS) and INENI-PT-GROUP-B/platform#51.
data "google_dns_managed_zone" "platform" {
  project = var.project_id
  name    = var.zone_name
}

# Grant roles/dns.admin on the zone to the in-cluster workloads that manage
# records (ExternalDNS, cert-manager) via Workload Identity. The service-account
# emails are supplied by the root module from the IAM module's outputs; until
# that wiring lands the list is empty and no bindings are created.
resource "google_dns_managed_zone_iam_member" "dns_admin" {
  for_each = toset(var.dns_admin_service_accounts)

  project      = var.project_id
  managed_zone = data.google_dns_managed_zone.platform.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${each.value}"
}
