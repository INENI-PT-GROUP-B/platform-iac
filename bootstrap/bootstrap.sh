#!/usr/bin/env bash
#
# bootstrap.sh — one-command, end-to-end platform bootstrap entry point.
#
# This is the single documented manual step of the project: a team member runs
# this script once, locally, authenticated via `gcloud auth login`, and the
# whole Day-1 platform is provisioned end-to-end with no further manual clicks.
#
# Phases:
#   0  preflight       — required CLIs, active gcloud account + ADC, project set
#   1  enable APIs      — idempotently enable the GCP APIs the platform needs
#   2  state + zone     — create the GCS state bucket and the persistent DNS
#                         zone if absent, then `terraform init`
#   3  terraform apply  — provision network, cluster, IAM, DNS bindings, backup
#   4  kubeconfig       — fetch cluster credentials for kubectl
#
# Idempotent throughout: a second run converges with no manual cleanup. Every
# mutating step is guarded by a describe-then-create check or is natively
# convergent (Terraform, `gcloud services enable`, `get-credentials`).
#
# Terraform runs locally as the executing team member (ADC). There are no
# long-lived service-account JSON keys anywhere in this path.
#
# The Argo CD bootstrap (Helm install + root App-of-Apps) is added in a later
# task (S2-01); it is intentionally not part of this script yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}/../terraform"

# Tee all output to bootstrap.log (gitignored) while keeping the console live.
# Truncates on each run so the log scopes to the current invocation only.
exec > >(tee "${SCRIPT_DIR}/bootstrap.log") 2>&1

log() {
  printf '[%s] %s\n' "${PHASE:-bootstrap}" "$*"
}

err() {
  printf '[%s] error: %s\n' "${PHASE:-bootstrap}" "$*" >&2
}

# Required GCP APIs, derived from the resources the Terraform code provisions:
#   compute        — VPC, subnet, firewall, GKE nodes
#   container      — GKE cluster and node pool
#   dns            — Cloud DNS managed zone and records
#   iam            — service accounts and Workload Identity bindings
#   iamcredentials — KSA→GSA token minting at runtime (generateAccessToken,
#                    signJwt) used by Workload Identity for ExternalDNS,
#                    cert-manager, ESO, and Crossplane provider-gcp; without
#                    it the cluster provisions cleanly but in-cluster
#                    impersonation fails at runtime
#   cloudresourcemanager — project-level IAM bindings
#   secretmanager  — ESO/Crossplane secret access (bindings created in IAM module)
#   storage        — state bucket and the CloudNativePG backup bucket
#   serviceusage   — the `services enable` call itself
REQUIRED_APIS=(
  compute.googleapis.com
  container.googleapis.com
  dns.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  cloudresourcemanager.googleapis.com
  secretmanager.googleapis.com
  storage.googleapis.com
  serviceusage.googleapis.com
)

# DNS zone parameters for the create-if-absent step (see DNS_SETUP.md). The zone
# is persistent infrastructure: created once, never destroyed on teardown, and
# only referenced (not owned) by Terraform.
DNS_ZONE_NAME="platform-zone"
DNS_ZONE_DNS_NAME="fhuebung.lol."
DNS_ZONE_DESCRIPTION="Public zone for the platform domain"

# --- Configuration -----------------------------------------------------------
# Load operator-provided values from bootstrap.env (gitignored). The committed
# bootstrap.env.example documents the required variables.
ENV_FILE="${SCRIPT_DIR}/bootstrap.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  err "missing ${ENV_FILE}"
  err "copy bootstrap.env.example to bootstrap.env and adjust the values:"
  err "  cp ${SCRIPT_DIR}/bootstrap.env.example ${ENV_FILE}"
  exit 1
fi
# shellcheck source=/dev/null
source "${ENV_FILE}"

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set in bootstrap.env}"
: "${GCP_REGION:?GCP_REGION must be set in bootstrap.env}"
: "${GCP_ZONE:?GCP_ZONE must be set in bootstrap.env}"
: "${TFSTATE_BUCKET_LOCATION:?TFSTATE_BUCKET_LOCATION must be set in bootstrap.env}"

# Single source of truth: feed bootstrap.env values into Terraform as TF_VAR_*.
# Avoids drift between bootstrap.env and a separate terraform.tfvars.
export TF_VAR_project_id="${GCP_PROJECT_ID}"
export TF_VAR_region="${GCP_REGION}"
export TF_VAR_zone="${GCP_ZONE}"

# --- Phase 0: preflight -------------------------------------------------------
PHASE="phase 0"
log "preflight checks"

for cli in gcloud terraform kubectl helm; do
  if ! command -v "${cli}" >/dev/null 2>&1; then
    err "${cli} not found on PATH; install it before running bootstrap"
    exit 1
  fi
done

# Avoid `... | grep -q .` here: under `pipefail`, grep's early exit can
# SIGPIPE gcloud (exit 141) and the pipeline would report failure even when
# an active account exists.
if [[ -z "$(gcloud auth list --filter=status:ACTIVE --format='value(account)')" ]]; then
  err "no active gcloud account; run 'gcloud auth login' first"
  exit 1
fi

# Terraform's google provider authenticates via Application Default Credentials,
# which are separate from the gcloud CLI account above.
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  err "no Application Default Credentials; run 'gcloud auth application-default login' first"
  exit 1
fi

# backend.tf cannot use variables, so the state-bucket name is hardcoded there.
# Fail fast if bootstrap.env points at a different project than that bucket.
BACKEND_BUCKET="$(awk -F'"' '/^[[:space:]]*bucket[[:space:]]*=/ {print $2; exit}' \
  "${TF_DIR}/backend.tf")"
EXPECTED_BUCKET="${GCP_PROJECT_ID}-tfstate"
if [[ "${BACKEND_BUCKET}" != "${EXPECTED_BUCKET}" ]]; then
  err "backend.tf bucket (${BACKEND_BUCKET}) does not match GCP_PROJECT_ID (${EXPECTED_BUCKET})"
  err "either correct GCP_PROJECT_ID in bootstrap.env or update terraform/backend.tf"
  exit 1
fi

log "setting active project to ${GCP_PROJECT_ID}"
gcloud config set project "${GCP_PROJECT_ID}" >/dev/null

# --- Phase 1: enable GCP APIs -------------------------------------------------
PHASE="phase 1"
log "enabling required GCP APIs (idempotent)"
gcloud services enable "${REQUIRED_APIS[@]}" --project="${GCP_PROJECT_ID}"

# --- Phase 2: state bucket, DNS zone, terraform init --------------------------
PHASE="phase 2"

# State bucket. Cannot be managed by Terraform (it would need state before any
# state exists), so it is created here, outside Terraform, idempotently.
BUCKET="${GCP_PROJECT_ID}-tfstate"
BUCKET_URL="gs://${BUCKET}"

if gcloud storage buckets describe "${BUCKET_URL}" >/dev/null 2>&1; then
  log "bucket ${BUCKET_URL} already exists, skipping creation"
else
  log "creating bucket ${BUCKET_URL} in ${TFSTATE_BUCKET_LOCATION}"
  gcloud storage buckets create "${BUCKET_URL}" \
    --project="${GCP_PROJECT_ID}" \
    --location="${TFSTATE_BUCKET_LOCATION}" \
    --uniform-bucket-level-access
fi

# Enabling versioning is idempotent — safe to run on every invocation.
log "ensuring object versioning is enabled on ${BUCKET_URL}"
gcloud storage buckets update "${BUCKET_URL}" --versioning >/dev/null

# Persistent DNS zone. The terraform/dns/ module references this zone via a
# data source, so it must exist before `terraform apply`. Like the state bucket,
# it is created here, outside Terraform, and is never destroyed on teardown.
if gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
  --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
  log "DNS zone ${DNS_ZONE_NAME} already exists, skipping creation"
else
  log "creating DNS zone ${DNS_ZONE_NAME} (${DNS_ZONE_DNS_NAME})"
  gcloud dns managed-zones create "${DNS_ZONE_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --dns-name="${DNS_ZONE_DNS_NAME}" \
    --visibility=public \
    --dnssec-state=off \
    --description="${DNS_ZONE_DESCRIPTION}"

  # One-time initial delegation: the assigned nameservers must be set at the
  # registrar (Porkbun). Persistent-zone reuse never reaches this branch, so the
  # registrar is never touched on a normal bootstrap (see DNS_SETUP.md).
  log "DNS zone created — delegate these nameservers at the registrar (one-time):"
  gcloud dns managed-zones describe "${DNS_ZONE_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --format='value(nameServers)'
fi

log "running terraform init"
# -lockfile=readonly: fail loudly on .terraform.lock.hcl drift instead of
# silently rewriting it on the operator's machine. Aligns with the pinning
# philosophy in platform/CONTRIBUTING.md § Tool Versions in CI.
terraform -chdir="${TF_DIR}" init -input=false -lockfile=readonly

# --- Phase 3: terraform apply -------------------------------------------------
PHASE="phase 3"
log "running terraform apply"
terraform -chdir="${TF_DIR}" apply -input=false -auto-approve

# --- Phase 4: kubeconfig ------------------------------------------------------
PHASE="phase 4"
CLUSTER_NAME="$(terraform -chdir="${TF_DIR}" output -raw cluster_name)"
CLUSTER_ZONE="$(terraform -chdir="${TF_DIR}" output -raw cluster_zone)"

log "fetching credentials for cluster ${CLUSTER_NAME} (${CLUSTER_ZONE})"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
  --zone="${CLUSTER_ZONE}" \
  --project="${GCP_PROJECT_ID}"

PHASE="bootstrap"
log "platform bootstrap complete; kubectl is configured for ${CLUSTER_NAME}"
log "Argo CD bootstrap (App-of-Apps) is added in a later task (S2-01)"
