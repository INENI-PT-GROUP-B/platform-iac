# main.tf
# Google Service Accounts and Workload Identity bindings for in-cluster
# platform workloads. Each workload gets a dedicated GSA bound to its KSA
# via the cluster's Workload Identity pool (<project>.svc.id.goog),
# enabled by the cluster module (S1-07).
#
# Out of scope for S1-08:
#   - DNS zone bindings for ExternalDNS / cert-manager  -> S1-09
#   - GCS backup bucket IAM                             -> S1-08a
#   - Crossplane ProviderConfig manifests               -> S2-10
#   - API enablement (iam, iamcredentials, secretmanager)
#                                                       -> bootstrap.sh / S1-10

# -----------------------------------------------------------------------------
# ExternalDNS
# -----------------------------------------------------------------------------

resource "google_service_account" "external_dns" {
  project      = var.project_id
  account_id   = var.external_dns_sa_id
  display_name = "ExternalDNS (Workload Identity)"
  description  = "Used by ExternalDNS to manage Cloud DNS record sets. Zone-scoped roles/dns.admin binding lives in the dns module (S1-09)."
}

resource "google_service_account_iam_member" "external_dns_wi" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.external_dns_namespace}/${var.external_dns_ksa_name}]"
}

# -----------------------------------------------------------------------------
# cert-manager
# -----------------------------------------------------------------------------

resource "google_service_account" "cert_manager" {
  project      = var.project_id
  account_id   = var.cert_manager_sa_id
  display_name = "cert-manager (Workload Identity)"
  description  = "Used by cert-manager to solve ACME DNS-01 challenges. Zone-scoped roles/dns.admin binding lives in the dns module (S1-09)."
}

resource "google_service_account_iam_member" "cert_manager_wi" {
  service_account_id = google_service_account.cert_manager.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.cert_manager_namespace}/${var.cert_manager_ksa_name}]"
}

# -----------------------------------------------------------------------------
# External Secrets Operator (ESO)
# -----------------------------------------------------------------------------

resource "google_service_account" "external_secrets" {
  project      = var.project_id
  account_id   = var.external_secrets_sa_id
  display_name = "External Secrets Operator (Workload Identity)"
  description  = "Reads secrets from Google Secret Manager and projects them as Kubernetes Secrets."
}

resource "google_service_account_iam_member" "external_secrets_wi" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.external_secrets_namespace}/${var.external_secrets_ksa_name}]"
}

resource "google_project_iam_member" "external_secrets_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets.email}"
}

# -----------------------------------------------------------------------------
# Crossplane provider-gcp
# -----------------------------------------------------------------------------

resource "google_service_account" "crossplane_provider_gcp" {
  project      = var.project_id
  account_id   = var.crossplane_provider_gcp_sa_id
  display_name = "Crossplane provider-gcp (Workload Identity)"
  description  = "Used by Crossplane provider-gcp to write per-tenant secrets (BasicAuth htpasswd) to Google Secret Manager."
}

resource "google_service_account_iam_member" "crossplane_provider_gcp_wi" {
  service_account_id = google_service_account.crossplane_provider_gcp.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.crossplane_namespace}/${var.crossplane_provider_gcp_ksa_name}]"
}

resource "google_project_iam_member" "crossplane_provider_gcp_secret_version_adder" {
  project = var.project_id
  role    = "roles/secretmanager.secretVersionAdder"
  member  = "serviceAccount:${google_service_account.crossplane_provider_gcp.email}"
}
