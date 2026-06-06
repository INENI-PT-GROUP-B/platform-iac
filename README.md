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

- Sufficient project IAM on the operator's account. Beyond the usual resource-creation roles, the `dns/` module sets a zone-scoped IAM policy on `platform-zone`, which requires the `dns.managedZones.setIamPolicy` permission. This is **not** included in `roles/dns.admin` (nor in `roles/editor`), so the apply fails with a `403 forbidden` on `google_dns_managed_zone_iam_member` unless the operator has it. Grant it via a least-privilege custom role (create it once, then bind it to each operator). The role also includes `getIamPolicy` — `roles/dns.admin` already covers it, but bundling both keeps the custom role self-contained for operators who only hold `roles/editor`:

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

- `roles/container.admin` on the project for the operator. Phase 5 installs Argo CD via Helm, whose `pre-install` hook (`argocd-redis-secret-init`) carries `hook-delete-policy: before-hook-creation`. Helm therefore issues a `delete` against the hook's `Role`/`RoleBinding` even on first install. GKE rejects this via Cloud IAM with `container.roles.delete` missing whenever the operator holds only `roles/editor`-equivalent permissions, and Phase 5 aborts with the release stuck in `pending-install`. `roles/container.admin` is the smallest standard role that covers the GKE RBAC delete verbs the chart's hooks need:

  ```bash
  gcloud projects add-iam-policy-binding dotted-axle-495612-f4 \
    --member="user:<operator-email>" \
    --role="roles/container.admin"
  ```

  Like the DNS Zone IAM Admin grant above, this is an operator-account prerequisite, not Terraform-managed — Terraform cannot grant the permissions it needs in order to run.

- `roles/secretmanager.admin` on the project for the operator. Phase 1a both writes new `SecretVersion`s (`secretmanager.versions.add`) and reads the latest version back (`secretmanager.versions.access`) to short-circuit a re-run when the payload is unchanged. The read permission is **not** part of `roles/editor`, so without this grant Phase 1a aborts with a clear `PERMISSION_DENIED` and the hint to grant the role:

  ```bash
  gcloud projects add-iam-policy-binding dotted-axle-495612-f4 \
    --member="user:<operator-email>" \
    --role="roles/secretmanager.admin"
  ```

  The phase intentionally fails loudly rather than treating the read failure as "payload differs" — otherwise the SecretVersion list would grow by one entry on every bootstrap run.

- **Optional:** a GitHub PAT in `GHCR_TOKEN` (in `bootstrap/bootstrap.env`) for Phase 1a to seed the shared GHCR pull secret into Google Secret Manager. The PAT only needs `read:packages` on the org's packages — this is the smallest scope that lets kubelet pull the private `app-frontend` image. The username defaults to the org slug (`ineni-pt-group-b`) and can be overridden via `GHCR_USERNAME`; for ghcr.io PAT auth the username is informational and any non-empty value works.

  When `GHCR_TOKEN` is unset, Phase 1a logs a warn and continues. Day-1 cluster bring-up still succeeds; tenant frontend image pulls then fail at runtime until the token is set and `bootstrap.sh` re-runs. The phase is idempotent: a re-run with the same token is a no-op, a re-run with a rotated token adds exactly one new SecretVersion in GSM. GitHub PATs typically expire after one year — rotate by updating `GHCR_TOKEN` and re-running `bootstrap.sh`.

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
- **Phase 1 — enable APIs:** idempotently enables the GCP APIs the platform needs (Compute, GKE, Cloud DNS, IAM, IAM Credentials, Resource Manager, Secret Manager, Storage, Service Usage). IAM Credentials is required for the Workload Identity token-minting calls that ExternalDNS, cert-manager, ESO, and Crossplane provider-gcp perform at runtime.
- **Phase 1a — GHCR pull-secret seed:** renders the dockerconfigjson for `ghcr.io` from `GHCR_TOKEN` and writes it into the `shared-ghcr-pull-secret` entry in Google Secret Manager (create-if-absent; new SecretVersion only when the payload differs from the latest). The per-tenant Crossplane Composition (`platform-gitops` S3-05) wires an `ExternalSecret` that pulls this entry into each tenant namespace as `ghcr-pull-secret`. Skipped with a warn when `GHCR_TOKEN` is unset.
- **Phase 2 — state bucket, DNS zone, init:** creates `gs://<project>-tfstate` (uniform bucket-level access, object versioning) and the persistent `platform-zone` Cloud DNS zone if they do not yet exist, then runs `terraform init`.
- **Phase 3 — apply:** runs `terraform apply` to provision the network, GKE cluster, IAM service accounts and Workload Identity bindings, DNS IAM bindings, and the backup bucket.
- **Phase 4 — kubeconfig:** fetches cluster credentials via `gcloud container clusters get-credentials`, so `kubectl` is ready against the new cluster.
- **Phase 5 — Argo CD:** installs Argo CD into the `argocd` namespace with the pinned `argo/argo-cd` Helm chart (values in [`bootstrap/argocd-values.yaml`](bootstrap/argocd-values.yaml)), waits for the server to roll out, then applies the root App-of-Apps ([`bootstrap/argocd-bootstrap.yaml`](bootstrap/argocd-bootstrap.yaml)). From here Argo CD reconciles every other platform component from `platform-gitops`.

The full run is logged to `bootstrap/bootstrap.log` (gitignored).

Two deliberate properties of this setup:

- The state bucket and the `platform-zone` DNS zone are **intentionally not managed by Terraform**. The state bucket would otherwise need state before any state exists (the bootstrap paradox); the DNS zone is persistent infrastructure (created once, delegated at the registrar once, never destroyed on teardown) and is only referenced by the `dns/` module via a data source. Both are created create-if-absent by the script before `terraform init`. See [`DNS_SETUP.md`](DNS_SETUP.md) for the zone lifecycle.
- The script is **idempotent and safe to re-run**: bucket and zone creation are skipped when they already exist, `gcloud services enable` is a no-op for already-enabled APIs, and `terraform apply` reconciles to the desired state.

For tearing the platform down and bringing it back up end-to-end (useful for validating that the bootstrap converges from a cold start without manual intervention), see [`TEARDOWN.md`](TEARDOWN.md).

### Argo CD access after bootstrap

Phase 5 installs Argo CD and applies a single root App-of-Apps named `root` that points at `platform-gitops/applications/`. That directory also contains a copy of the same `root` Application (S2-02), so Argo CD adopts and self-manages the root on its first sync — there is never a second, competing root.

Argo CD's Ingress (`argocd.fhuebung.lol`, TLS via the wildcard secret `wildcard-fhuebung-lol-tls`) is created at bootstrap time but stays dormant until Traefik, cert-manager, and the wildcard certificate exist. Until then, reach the UI via port-forward:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
# initial admin password:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Storing the admin password in Google Secret Manager (instead of reading the chart-generated secret) is tracked as a follow-up, not part of this bootstrap.

## Modules

The root module under `terraform/` composes the per-concern child modules:

- `network/` — VPC, subnetwork with GKE secondary ranges, baseline firewall rules
- `cluster/` — Standard zonal GKE cluster with Workload Identity and Dataplane V2
- `dns/` — Public Cloud DNS managed zone for the platform domain `fhuebung.lol`, with zone-scoped `roles/dns.admin` bindings for the ExternalDNS and cert-manager service accounts
- `iam/` — Google Service Accounts and Workload Identity bindings for in-cluster platform workloads (ExternalDNS, cert-manager, ESO, Crossplane provider-gcp)
- `backup/` — Shared GCS bucket for CloudNativePG per-tenant database backups (Barman, 30-day retention), with bucket-scoped IAM letting Crossplane provider-gcp add per-tenant prefix-scoped write bindings
