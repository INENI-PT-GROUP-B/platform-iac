# backend.tf
# Remote state in the GCS bucket created by bootstrap/bootstrap.sh.
# The bucket name is "<project>-tfstate"; it must exist before `terraform init`.
# The gcs backend block cannot use variables, so the bucket name is hardcoded.
terraform {
  backend "gcs" {
    bucket = "dotted-axle-495612-f4-tfstate"
    prefix = "terraform/state"
  }
}
