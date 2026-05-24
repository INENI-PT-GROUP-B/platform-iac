# main.tf
# Public Cloud DNS managed zone for the platform domain, plus a zone-scoped
# roles/dns.admin binding for the workloads that manage records.
# The provider configuration is inherited from the root module.

# Public managed zone for the platform domain. ExternalDNS writes A/CNAME
# records for tenant ingresses here; cert-manager solves ACME DNS-01 challenges
# by writing TXT records. DNSSEC is off, matching the registrar (Porkbun).
resource "google_dns_managed_zone" "platform" {
  project     = var.project_id
  name        = var.zone_name
  dns_name    = var.dns_name
  description = var.zone_description
  visibility  = "public"

  dnssec_config {
    state = "off"
  }
}

# Grant roles/dns.admin on the zone to the in-cluster workloads that manage
# records (ExternalDNS, cert-manager) via Workload Identity. The service-account
# emails are supplied by the root module from the IAM module's outputs; until
# that wiring lands the list is empty and no bindings are created.
resource "google_dns_managed_zone_iam_member" "dns_admin" {
  for_each = toset(var.dns_admin_service_accounts)

  project      = var.project_id
  managed_zone = google_dns_managed_zone.platform.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${each.value}"
}
