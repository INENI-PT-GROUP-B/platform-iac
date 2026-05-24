# main.tf
# Shared GCS bucket for CloudNativePG per-tenant database backups (Barman).
# One bucket; each tenant writes under its own "<tenant>/" prefix. Per the
# architecture docs, GCS auth is via Workload Identity bound to the per-tenant
# ServiceAccount, and the per-tenant, prefix-scoped IAM binding is created by
# the Crossplane Composition at onboarding (S3-04). This module provisions the
# bucket and grants the Crossplane provider-gcp SA the ability to manage this
# bucket's IAM so it can add those per-tenant bindings.

resource "google_storage_bucket" "pg_backups" {
  project                     = var.project_id
  name                        = "${var.project_id}-pg-backups"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning {
    enabled = false
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# Bucket-scoped storage.admin for Crossplane provider-gcp: lets the per-tenant
# Composition add prefix-scoped write bindings for each tenant's ServiceAccount.
resource "google_storage_bucket_iam_member" "provider_gcp_admin" {
  bucket = google_storage_bucket.pg_backups.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${var.crossplane_provider_gcp_sa_email}"
}
