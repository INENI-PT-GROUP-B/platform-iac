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

  # Destroy the bucket together with the rest of the platform on a
  # `terraform destroy`. Backup objects are not promised to survive a
  # teardown — the persistent set is `tfstate`, the Cloud DNS zone, and
  # the GSM secrets. See `platform-gitops/docs/cluster-redeploy-validation.md`
  # § Persistence-boundary inventory (S4-04b, `platform-gitops#65`) and
  # `TEARDOWN.md` § Phase B. Without this, a populated bucket blocks
  # `terraform destroy` with `Error trying to delete bucket ... without
  # force_destroy set to true`, surfaced live on 2026-06-15.
  force_destroy = true

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

# Least-privilege IAM for Crossplane provider-gcp: its only job on this bucket is
# to manage the IAM policy so the per-tenant Composition (S3-04) can add
# prefix-scoped write bindings for each tenant's ServiceAccount. A custom role
# with just the two IAM-policy permissions is tighter than roles/storage.admin,
# which would also let it delete the bucket and read/write every tenant's objects.
resource "google_project_iam_custom_role" "pg_backups_iam_admin" {
  project     = var.project_id
  role_id     = "pgBackupsBucketIamAdmin"
  title       = "PG Backups Bucket IAM Admin"
  description = "Manage the IAM policy of the pg-backups bucket so the Crossplane Composition can add per-tenant prefix-scoped write bindings. No object or bucket-lifecycle access."
  permissions = [
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
  ]
}

resource "google_storage_bucket_iam_member" "provider_gcp_iam_admin" {
  bucket = google_storage_bucket.pg_backups.name
  role   = google_project_iam_custom_role.pg_backups_iam_admin.id
  member = "serviceAccount:${var.crossplane_provider_gcp_sa_email}"
}
