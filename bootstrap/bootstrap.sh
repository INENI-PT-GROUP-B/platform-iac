#!/usr/bin/env bash
#
# bootstrap.sh — platform bootstrap entry point.
#
# Scope (S1-05): create the Terraform remote-state bucket so that
# `terraform init` against the GCS backend succeeds. The bucket cannot be
# managed by Terraform itself (it would need state to exist first), so it is
# created here, outside Terraform, idempotently.
#
# The remaining bootstrap phases (preflight for terraform/kubectl/helm, GCP
# API enablement, `terraform apply`, kubeconfig retrieval, Argo CD bootstrap,
# and logging to bootstrap.log) are added in S1-10. This script is structured
# so those phases slot in after the state phase below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[state] %s\n' "$*"
}

err() {
  printf '[state] error: %s\n' "$*" >&2
}

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
: "${TFSTATE_BUCKET_LOCATION:?TFSTATE_BUCKET_LOCATION must be set in bootstrap.env}"

# --- Preflight ---------------------------------------------------------------
# Only the checks relevant to the state phase. Broader preflight is S1-10.
if ! command -v gcloud >/dev/null 2>&1; then
  err "gcloud not found on PATH; install the Google Cloud SDK first"
  exit 1
fi

if ! gcloud auth list --filter=status:ACTIVE --format='value(account)' \
  | grep -q .; then
  err "no active gcloud account; run 'gcloud auth login' first"
  exit 1
fi

# --- State bucket ------------------------------------------------------------
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
gcloud storage buckets update "${BUCKET_URL}" --versioning

log "state backend ready; run 'terraform init' in terraform/ next"

# --- Remaining phases (S1-10) ------------------------------------------------
# preflight (terraform/kubectl/helm), GCP API enablement, terraform apply,
# kubeconfig retrieval, Argo CD bootstrap, bootstrap.log redirection.
