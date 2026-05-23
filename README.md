# platform-iac

Terraform code for the Day 1 platform bootstrap on Google Cloud Platform. The infrastructure is applied **locally** through `bootstrap/bootstrap.sh`, executed by a team member authenticated via `gcloud auth login`. There is no CI-based Terraform pipeline and no long-lived service account keys.

## Terraform remote state

Terraform state is stored in a versioned GCS bucket `gs://<project>-tfstate` (for example `gs://dotted-axle-495612-f4-tfstate`). The GCS backend also provides state locking, so no separate lock resource is required.

This creates a chicken-and-egg problem: `terraform init` needs the bucket to exist, but the bucket cannot be managed by Terraform itself (it would need state before any state exists). `bootstrap/bootstrap.sh` solves this by creating the bucket outside Terraform, idempotently, before `terraform init` runs.

## Bootstrap order

Run these steps once per environment. The bootstrap step is idempotent and safe to re-run.

1. Authenticate with GCP:

   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

2. Create your local bootstrap config from the committed example and adjust the values:

   ```bash
   cp bootstrap/bootstrap.env.example bootstrap/bootstrap.env
   # edit bootstrap/bootstrap.env (GCP_PROJECT_ID, GCP_REGION, TFSTATE_BUCKET_LOCATION)
   ```

   `bootstrap/bootstrap.env` is gitignored and must never be committed.

3. Create the Terraform state bucket:

   ```bash
   ./bootstrap/bootstrap.sh
   ```

   This creates `gs://<project>-tfstate` with uniform bucket-level access and object versioning enabled, skipping creation if the bucket already exists.

4. Initialize Terraform against the GCS backend, then continue with the normal workflow:

   ```bash
   cd terraform
   terraform init    # succeeds because the backend bucket now exists
   terraform plan
   terraform apply
   ```

   Running `terraform init` before the bucket exists fails with a descriptive backend error — run `bootstrap/bootstrap.sh` first.

Two deliberate properties of this setup:

- `bootstrap/bootstrap.sh` is **idempotent and safe to re-run**: it skips bucket creation if the bucket already exists and only re-asserts versioning.
- The state bucket is **intentionally not managed by Terraform** to avoid the bootstrap paradox (Terraform would need state before any state exists).

The full one-command bootstrap (GCP API enablement, `terraform apply`, kubeconfig retrieval, and the Argo CD bootstrap) is added to `bootstrap/bootstrap.sh` in a later task. At this stage the script only establishes the Terraform state backend.
