#!/usr/bin/env bash
#
# bootstrap.sh — one-command, end-to-end platform bootstrap entry point.
#
# This is the single documented manual step of the project: a team member runs
# this script once, locally, authenticated via `gcloud auth login`, and the
# whole Day-1 platform is provisioned end-to-end with no further manual clicks.
#
# Phases:
#   0  preflight        — required CLIs, active gcloud account + ADC, project set
#   1  enable APIs      — idempotently enable the GCP APIs the platform needs
#   1a ghcr secret seed — write the shared GHCR pull secret into Google Secret
#                         Manager from an operator-supplied PAT; tenant
#                         ExternalSecrets sync from this GSM entry. Skipped
#                         with a warn if GHCR_TOKEN is unset (see § Phase 1a)
#   2  state + zone     — create the GCS state bucket and the persistent DNS
#                         zone if absent, then `terraform init`
#   3  terraform apply  — provision network, cluster, IAM, DNS bindings, backup
#   4  kubeconfig       — fetch cluster credentials for kubectl
#   5  argo cd          — install Argo CD (Helm) + apply the root App-of-Apps,
#                         after which Argo CD self-manages every platform
#                         component from platform-gitops
#
# Idempotent throughout: a second run converges with no manual cleanup. Every
# mutating step is guarded by a describe-then-create check or is natively
# convergent (Terraform, `gcloud services enable`, `get-credentials`).
#
# Terraform runs locally as the executing team member (ADC). There are no
# long-lived service-account JSON keys anywhere in this path.
#
# Phase 5 installs Argo CD via Helm and applies the root App-of-Apps; from that
# point Argo CD reconciles every other platform component from platform-gitops,
# so Argo CD itself is the only thing this script installs imperatively.

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

# Shared GHCR pull secret parameters (Phase 1a). The GSM secret holds a
# dockerconfigjson for ghcr.io that ESO syncs into every tenant namespace as
# the imagePullSecret for the private app-frontend image. The GSM ID matches
# the dash form documented in platform-gitops#39; GSM secret IDs must satisfy
# ^[a-zA-Z][a-zA-Z0-9_-]{0,254}$ so the historical slash form is not usable.
# Username default is the org slug — for PATs, the username field is informational
# and any non-empty value works against ghcr.io.
GHCR_GSM_SECRET_ID="shared-ghcr-pull-secret"
GHCR_USERNAME_DEFAULT="ineni-pt-group-b"

# Argo CD install parameters (Phase 5). The chart version is pinned (no floating
# version) per CONTRIBUTING § Tool Versions in CI; bump it deliberately.
ARGOCD_NAMESPACE="argocd"
ARGOCD_HELM_REPO_NAME="argo"
ARGOCD_HELM_REPO_URL="https://argoproj.github.io/argo-helm"
ARGOCD_CHART="argo/argo-cd"
ARGOCD_CHART_VERSION="9.5.16"
ARGOCD_VALUES_FILE="${SCRIPT_DIR}/argocd-values.yaml"
ARGOCD_ROOT_APP_FILE="${SCRIPT_DIR}/argocd-bootstrap.yaml"

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

# --- Phase 1a: seed shared GHCR pull secret in GSM ----------------------------
# Materialises the dockerconfigjson for ghcr.io as an entry in Google Secret
# Manager. The per-tenant Composition (platform-gitops#39, S3-05) wires an
# ExternalSecret that pulls this entry into each tenant namespace as
# `ghcr-pull-secret`, which kubelet uses to pull the private app-frontend image.
#
# The GHCR PAT is the only credential the platform cannot machine-generate
# (no Workload Identity path to ghcr.io). It is operator-supplied via
# bootstrap.env. When unset, this phase is skipped with a warn — Day-1 cluster
# bring-up succeeds, and only per-tenant frontend image pulls fail later.
#
# Idempotent: create-if-absent for the secret container; add a new SecretVersion
# only when the rendered dockerconfigjson differs byte-for-byte from the latest
# version. A re-run with the same GHCR_TOKEN is a no-op; a re-run with a rotated
# token adds exactly one new SecretVersion.
#
# Log hygiene: bootstrap.log captures stdout+stderr (see exec redirect above),
# so neither the PAT nor the rendered payload is ever printed. Only the GSM ID
# and version metadata land in the log.
PHASE="phase 1a"
if [[ -z "${GHCR_TOKEN:-}" ]]; then
  log "GHCR_TOKEN not set — skipping shared GHCR pull-secret seed"
  log "  tenant frontend image pulls will fail until GHCR_TOKEN is set and this phase re-runs"
else
  ghcr_username="${GHCR_USERNAME:-${GHCR_USERNAME_DEFAULT}}"
  log "seeding ${GHCR_GSM_SECRET_ID} in Google Secret Manager (user: ${ghcr_username})"

  # Render the dockerconfigjson payload. The base64 output of `username:token`
  # is guaranteed to contain only [A-Za-z0-9+/=], so direct string interpolation
  # into the JSON template is safe — no escaping needed, no jq dependency.
  # `base64 -w0` prevents line-wrapping (coreutils on Linux; macOS default emits
  # one line already).
  auth_b64="$(printf '%s:%s' "${ghcr_username}" "${GHCR_TOKEN}" | base64 -w0)"
  payload="{\"auths\":{\"ghcr.io\":{\"auth\":\"${auth_b64}\"}}}"

  if gcloud secrets describe "${GHCR_GSM_SECRET_ID}" \
    --project="${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    log "secret ${GHCR_GSM_SECRET_ID} already exists, checking latest version"
    # Separate stderr from stdout so a permission failure produces a clear error
    # instead of being silently treated as "payload differs" — that would re-add
    # a SecretVersion on every bootstrap run and grow the version list linearly.
    access_err="$(mktemp)"
    if current="$(gcloud secrets versions access latest \
      --secret="${GHCR_GSM_SECRET_ID}" \
      --project="${GCP_PROJECT_ID}" 2>"${access_err}")"; then
      rm -f "${access_err}"
      if [[ "${current}" == "${payload}" ]]; then
        log "latest version matches current dockerconfigjson, no new version added"
      else
        log "payload differs from latest version, adding new SecretVersion"
        printf '%s' "${payload}" | gcloud secrets versions add "${GHCR_GSM_SECRET_ID}" \
          --project="${GCP_PROJECT_ID}" \
          --data-file=- >/dev/null
      fi
    else
      access_msg="$(cat "${access_err}")"
      rm -f "${access_err}"
      # NOT_FOUND happens when the container exists but has no enabled version
      # yet (rare — only if an earlier run failed between `create` and version
      # write). Treat that as "needs a version" and add one. Anything else
      # (typically PERMISSION_DENIED on secretmanager.versions.access) is a
      # configuration problem: fail loudly with the operator-grant hint rather
      # than silently re-adding a version each run.
      if [[ "${access_msg}" == *"NOT_FOUND"* ]]; then
        log "secret container exists without an enabled version, adding initial SecretVersion"
        printf '%s' "${payload}" | gcloud secrets versions add "${GHCR_GSM_SECRET_ID}" \
          --project="${GCP_PROJECT_ID}" \
          --data-file=- >/dev/null
      else
        err "cannot read latest version of ${GHCR_GSM_SECRET_ID}:"
        err "${access_msg}"
        err "operator account likely lacks secretmanager.versions.access — grant roles/secretmanager.admin"
        exit 1
      fi
    fi
  else
    log "creating secret ${GHCR_GSM_SECRET_ID} with initial version"
    printf '%s' "${payload}" | gcloud secrets create "${GHCR_GSM_SECRET_ID}" \
      --project="${GCP_PROJECT_ID}" \
      --replication-policy=automatic \
      --data-file=- >/dev/null
  fi

  # Zero out the rendered payload from this shell's memory; the variable is no
  # longer needed and any subprocess inheriting the env would otherwise see it.
  unset auth_b64 payload
fi

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

# --- Phase 5: Argo CD bootstrap -----------------------------------------------
PHASE="phase 5"
log "adding/updating the Argo CD Helm repo (idempotent)"
helm repo add "${ARGOCD_HELM_REPO_NAME}" "${ARGOCD_HELM_REPO_URL}" --force-update >/dev/null
helm repo update "${ARGOCD_HELM_REPO_NAME}" >/dev/null

log "installing/upgrading Argo CD (chart ${ARGOCD_CHART} ${ARGOCD_CHART_VERSION})"
helm upgrade --install argocd "${ARGOCD_CHART}" \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --values "${ARGOCD_VALUES_FILE}" \
  --wait --timeout 10m

log "applying the root App-of-Apps (Argo CD now self-manages from platform-gitops)"
# Server-side apply: the root is also reconciled from applications/root.yaml
# (S2-02) via server-side apply, so applying it server-side here lets Argo CD
# take over field ownership cleanly on first sync — no client-side
# last-applied-configuration annotation and no field-manager conflict.
kubectl apply --server-side --field-manager=bootstrap.sh -f "${ARGOCD_ROOT_APP_FILE}"

PHASE="bootstrap"
log "platform bootstrap complete; kubectl is configured for ${CLUSTER_NAME}"
log "Argo CD installed and root App-of-Apps applied; it self-manages from platform-gitops"
log "UI (until Traefik + wildcard cert exist): kubectl -n argocd port-forward svc/argocd-server 8080:80"
