# outputs.tf
# GSA emails are the canonical reference for IAM member strings
# ("serviceAccount:<email>") used by downstream modules:
#   - dns module (S1-09) for zone-scoped roles/dns.admin bindings on
#     ExternalDNS and cert-manager
#   - any future module that needs to reference the same identities
# IDs (projects/<id>/serviceAccounts/<email>) are exposed for symmetry where
# the resource-id form is required by a binding resource.

output "external_dns_sa_email" {
  description = "Email of the ExternalDNS Google Service Account"
  value       = google_service_account.external_dns.email
}

output "external_dns_sa_id" {
  description = "Fully qualified ID of the ExternalDNS Google Service Account"
  value       = google_service_account.external_dns.id
}

output "cert_manager_sa_email" {
  description = "Email of the cert-manager Google Service Account"
  value       = google_service_account.cert_manager.email
}

output "cert_manager_sa_id" {
  description = "Fully qualified ID of the cert-manager Google Service Account"
  value       = google_service_account.cert_manager.id
}

output "external_secrets_sa_email" {
  description = "Email of the External Secrets Operator Google Service Account"
  value       = google_service_account.external_secrets.email
}

output "crossplane_provider_gcp_sa_email" {
  description = "Email of the Crossplane provider-gcp Google Service Account"
  value       = google_service_account.crossplane_provider_gcp.email
}
