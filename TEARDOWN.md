# Teardown and Re-Bootstrap

This document describes how to tear the platform down and bring it back up
end-to-end. The primary use case is validating that `bootstrap.sh` converges
from a cold start without manual intervention — for example after merging
operator-IAM or Terraform changes that we want to see exercised on a fresh
provision.

The split between persistent and disposable infrastructure mirrors the
`bootstrap.sh` design (see [`README.md`](./README.md) and
[`DNS_SETUP.md`](./DNS_SETUP.md)). Persistent items survive teardown by
design: the GCS state bucket (`<project>-tfstate`), the Cloud DNS managed
zone `platform-zone`, and the project-level API enablements. Everything
else — VPC, GKE cluster, GSAs and IAM bindings, the pg-backups bucket — is
managed by Terraform and recreated on the next bootstrap.

## Total wallclock

Measured against a real teardown + re-bootstrap on `dotted-axle-495612-f4` (2026-05-30, post-#44):

| Phase | Time |
|---|---|
| A — drain GitOps state | ~2 min |
| B — `terraform destroy` (20 resources) | ~9 min |
| C — cloud hygiene check | <1 min |
| D — re-bootstrap (`bootstrap.sh`) | ~15 min |
| E — end-to-end verification | ~3 min |
| **Total** | **~30 min** |

Cluster create dominates Phase D (~7 min), Argo CD reconciliation dominates Phase E (cert issuance, DNS propagation, all twelve children to Healthy).

## Prerequisites

- Same as `bootstrap.sh` (`gcloud auth login` + `gcloud auth application-default login`, `bootstrap/bootstrap.env` populated, operator IAM per [`README.md`](./README.md) §Prerequisites).
- `kubectl` configured against the cluster you want to tear down (Phase 4 of the previous bootstrap set this; verify with `kubectl config current-context`).

## Phase A — drain GitOps state

Goal: let ExternalDNS delete the records it owns (`argocd.fhuebung.lol`, `*.fhuebung.lol`, plus the matching TXT owner records) before the cluster is torn down. Otherwise those records stay in `platform-zone` and on the next bootstrap ExternalDNS will adopt and rewrite them to the new LoadBalancer IP — functional but with a brief window of resolution to a dead IP.

```bash
# 1. Stop Argo CD so it does not reconcile against the teardown
kubectl -n argocd scale deploy --all --replicas=0
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0

# 2. Delete the Ingress and the LoadBalancer Service ExternalDNS watches
kubectl -n argocd delete ingress argocd-server
kubectl -n traefik delete svc traefik

# 3. Wait one ExternalDNS poll cycle (default 1 min) and verify
sleep 75
gcloud dns record-sets list \
  --zone=platform-zone \
  --project="${GCP_PROJECT_ID}"
# Expected: only NS and SOA remain.
```

If A/TXT records remain (e.g. because the ExternalDNS pod was already gone before its next poll), delete them manually with `gcloud dns record-sets delete`.

Skipping Phase A is not catastrophic — ExternalDNS reclaims its records on the next bootstrap via the `TXTOwnerID=gke-prod` marker — but it leaves a brief misresolution window and is not the clean test path.

## Phase B — `terraform destroy`

```bash
cd platform-iac/

# Load the same TF_VAR_* values bootstrap.sh sets
set -a; source bootstrap/bootstrap.env; set +a
export TF_VAR_project_id="${GCP_PROJECT_ID}" \
       TF_VAR_region="${GCP_REGION}" \
       TF_VAR_zone="${GCP_ZONE}"

terraform -chdir=terraform destroy
# Review the plan; confirm with `yes`.
```

Destroyed: VPC + subnet + firewall rules, GKE cluster + nodepool, all GSAs and their WI bindings, zone-scoped `roles/dns.admin` and project-level `roles/dns.reader` bindings, the pg-backups bucket.

Not destroyed (persistent by design):

- `platform-zone` Cloud DNS managed zone — referenced as a data source, not owned
- `gs://<project>-tfstate` state bucket — chicken-and-egg with the backend
- Project-level API enablements — not Terraform resources

## Phase C — cloud hygiene check

GKE usually cleans up Service-Type=LoadBalancer artefacts when the cluster is destroyed, but a few resources occasionally linger and will block the next VPC create.

```bash
gcloud compute forwarding-rules list --project="${GCP_PROJECT_ID}"
gcloud compute backend-services  list --project="${GCP_PROJECT_ID}"
gcloud compute target-pools      list --project="${GCP_PROJECT_ID}"
gcloud compute addresses         list --project="${GCP_PROJECT_ID}"
gcloud compute disks             list --project="${GCP_PROJECT_ID}"
```

Expected: each command lists nothing project-managed. Anything left over from the platform (forwarding rules pointing at deleted target pools, orphaned LB IPs, PVC-backed disks) should be deleted manually before Phase D.

## Phase D — re-bootstrap

```bash
./bootstrap/bootstrap.sh
```

Phase-by-phase expectation:

- **Phase 0** — preflight passes; auth is still active from the previous session.
- **Phase 1** — APIs already enabled, `gcloud services enable` is a no-op.
- **Phase 2** — state bucket and DNS zone survived, both create-if-absent paths skip to existing.
- **Phase 3** — `terraform apply` provisions everything fresh (~7-10 min, cluster create dominates).
- **Phase 4** — `gcloud container clusters get-credentials` rewrites the kubeconfig entry against the new cluster.
- **Phase 5** — `helm upgrade --install argocd … --wait` blocks until the Argo CD server is rolled out, then `kubectl apply` of the root App-of-Apps. From here Argo CD reconciles every other platform component from `platform-gitops` asynchronously over the next ~5-10 min.

## Phase E — end-to-end verification

```bash
# All twelve Applications report Synced/Healthy?
kubectl -n argocd get applications

# ExternalDNS reconciling cleanly (no 403 from ManagedZones.List)?
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns --tail=10

# Records re-materialised in the zone?
gcloud dns record-sets list --zone=platform-zone --project="${GCP_PROJECT_ID}"

# HTTPS endpoint live with valid Let's Encrypt cert?
curl -sS -o /dev/null \
  -w "HTTP %{http_code} | TLS %{ssl_verify_result}\n" \
  https://argocd.fhuebung.lol/
# Expected: HTTP 200 | TLS 0
```

## What this run validates

- Terraform-destroy is a clean inverse of apply (no `--target` workarounds).
- The persistent zone survives and the platform reconnects to it on the next apply.
- The chain that needed manual `gcloud` workarounds during the first end-to-end run is now Terraform-managed and the cold-start path is dry: ExternalDNS gets `roles/dns.reader` from `terraform/dns/` (#43, #44) and writes records on the first poll instead of looping on 403.
- The state bucket is reused (terraform init finds the backend immediately).
- GKE cleans up its LoadBalancer artefacts on cluster destroy (Phase C).

## What this run does not validate

- The `roles/container.admin` README prerequisite — the operator running this teardown already holds it. Validating the prereq requires a fresh operator account or temporarily removing the role (not recommended).
- The bootstrap preflight hardening tracked in [#45](https://github.com/INENI-PT-GROUP-B/platform-iac/issues/45) — out of scope.
