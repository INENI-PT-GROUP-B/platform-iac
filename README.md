# platform-iac

Terraform code for the Day 1 platform bootstrap on Google Cloud Platform. The infrastructure is applied **locally** through `bootstrap/bootstrap.sh`, executed by a team member authenticated via `gcloud auth login`. There is no CI-based Terraform pipeline and no long-lived service account keys.

## Terraform remote state

Terraform state is stored in a versioned GCS bucket `gs://<project>-tfstate` (for example `gs://dotted-axle-495612-f4-tfstate`). The GCS backend also provides state locking, so no separate lock resource is required.

This creates a chicken-and-egg problem: `terraform init` needs the bucket to exist, but the bucket cannot be managed by Terraform itself (it would need state before any state exists). `bootstrap/bootstrap.sh` solves this by creating the bucket outside Terraform, idempotently, before `terraform init` runs.

## Bootstrap order

`bootstrap/bootstrap.sh` provisions the whole Day-1 platform end-to-end. It is the single documented manual step of the project: run it once, locally, and no further manual clicks are needed. It is idempotent and safe to re-run — a second run converges with no manual cleanup.

### Prerequisites

- `gcloud`, `terraform`, `kubectl`, and `helm` on your `PATH`.
- An authenticated GCP session, both the CLI account and Application Default Credentials (Terraform's google provider uses ADC):

  ```bash
  gcloud auth login
  gcloud auth application-default login
  ```

  Make sure both authenticate as the **same** principal — Terraform uses ADC, not the CLI account, so a mismatch can cause permission errors that the `gcloud auth list` account would not predict.

- Sufficient project IAM on the operator's account. Beyond the usual resource-creation roles, the `dns/` module sets a zone-scoped IAM policy on `platform-zone`, which requires the `dns.managedZones.getIamPolicy` and `dns.managedZones.setIamPolicy` permissions. These are **not** included in `roles/dns.admin` (nor in `roles/editor`), so the apply fails with a `403 forbidden` on `google_dns_managed_zone_iam_member` unless the operator has them. Grant them via a least-privilege custom role (create it once, then bind it to each operator):

  ```bash
  # Create the custom role once for the project.
  gcloud iam roles create dnsZoneIamAdmin \
    --project=dotted-axle-495612-f4 \
    --title="DNS Zone IAM Admin" \
    --description="Manage IAM policy on Cloud DNS managed zones (for bootstrap.sh)" \
    --permissions=dns.managedZones.getIamPolicy,dns.managedZones.setIamPolicy

  # Bind it to the operator running bootstrap.sh.
  gcloud projects add-iam-policy-binding dotted-axle-495612-f4 \
    --member="user:<operator-email>" \
    --role="projects/dotted-axle-495612-f4/roles/dnsZoneIamAdmin"
  ```

  (`roles/owner` also grants these permissions and would work, but the custom role keeps the operator grant least-privilege.)

### Run

1. Create your local bootstrap config from the committed example and adjust the values:

   ```bash
   cp bootstrap/bootstrap.env.example bootstrap/bootstrap.env
   # edit bootstrap/bootstrap.env (GCP_PROJECT_ID, GCP_REGION, GCP_ZONE, TFSTATE_BUCKET_LOCATION)
   ```

   `bootstrap/bootstrap.env` is gitignored and must never be committed.

   This file is the single source of truth for the bootstrap run: `bootstrap.sh` exports `GCP_PROJECT_ID`, `GCP_REGION`, and `GCP_ZONE` as `TF_VAR_*` so Terraform reads the same values. There is no `terraform.tfvars` to maintain in parallel.

2. Run the script:

   ```bash
   ./bootstrap/bootstrap.sh
   ```

The script runs the following phases in order:

- **Phase 0 — preflight:** checks the required CLIs, an active `gcloud` account, present Application Default Credentials, asserts that the state-bucket name in `terraform/backend.tf` matches `${GCP_PROJECT_ID}-tfstate`, and sets the active project.
- **Phase 1 — enable APIs:** idempotently enables the GCP APIs the platform needs (Compute, GKE, Cloud DNS, IAM, Resource Manager, Secret Manager, Storage, Service Usage).
- **Phase 2 — state bucket, DNS zone, init:** creates `gs://<project>-tfstate` (uniform bucket-level access, object versioning) and the persistent `platform-zone` Cloud DNS zone if they do not yet exist, then runs `terraform init`.
- **Phase 3 — apply:** runs `terraform apply` to provision the network, GKE cluster, IAM service accounts and Workload Identity bindings, DNS IAM bindings, and the backup bucket.
- **Phase 4 — kubeconfig:** fetches cluster credentials via `gcloud container clusters get-credentials`, so `kubectl` is ready against the new cluster.

The full run is logged to `bootstrap/bootstrap.log` (gitignored).

Two deliberate properties of this setup:

- The state bucket and the `platform-zone` DNS zone are **intentionally not managed by Terraform**. The state bucket would otherwise need state before any state exists (the bootstrap paradox); the DNS zone is persistent infrastructure (created once, delegated at the registrar once, never destroyed on teardown) and is only referenced by the `dns/` module via a data source. Both are created create-if-absent by the script before `terraform init`. See [`DNS_SETUP.md`](DNS_SETUP.md) for the zone lifecycle.
- The script is **idempotent and safe to re-run**: bucket and zone creation are skipped when they already exist, `gcloud services enable` is a no-op for already-enabled APIs, and `terraform apply` reconciles to the desired state.

The Argo CD bootstrap (Helm install + root App-of-Apps pointing at `platform-gitops`) is added to the script in a later task (S2-01). After that, Argo CD reconciles everything else from `platform-gitops`.

## Modules

The root module under `terraform/` composes the per-concern child modules:

- `network/` — VPC, subnetwork with GKE secondary ranges, baseline firewall rules
- `cluster/` — Standard zonal GKE cluster with Workload Identity and Dataplane V2
- `dns/` — Public Cloud DNS managed zone for the platform domain `fhuebung.lol`, with zone-scoped `roles/dns.admin` bindings for the ExternalDNS and cert-manager service accounts
- `iam/` — Google Service Accounts and Workload Identity bindings for in-cluster platform workloads (ExternalDNS, cert-manager, ESO, Crossplane provider-gcp)
- `backup/` — Shared GCS bucket for CloudNativePG per-tenant database backups (Barman, 30-day retention), with bucket-scoped IAM letting Crossplane provider-gcp add per-tenant prefix-scoped write bindings
