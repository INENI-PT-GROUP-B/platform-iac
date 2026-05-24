# outputs.tf
# The bucket name is consumed by the CloudNativePG Composition (S3-04) as the
# backup destination root: gs://<bucket>/<tenant>/.

output "bucket_name" {
  description = "Name of the CloudNativePG backup bucket"
  value       = google_storage_bucket.pg_backups.name
}

output "bucket_url" {
  description = "gs:// URL of the CloudNativePG backup bucket"
  value       = google_storage_bucket.pg_backups.url
}
