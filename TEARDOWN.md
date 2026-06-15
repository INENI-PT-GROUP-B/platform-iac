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

Two real teardown + re-bootstrap runs are on record. The 2026-05-30 reference is what the procedure converges to once all known gaps are closed; the 2026-06-15 run measured the cost of surfacing the gaps the first time, each tracked under a follow-up issue. The two are kept side-by-side so an operator can see whether their environment is closer to the reference or to the discovery run.

| Phase | Reference (2026-05-30) | S4-04b run (2026-06-15) | Drivers of the 2026-06-15 delta |
| --- | --- | --- | --- |
| A — drain GitOps state | ~2 min | ~6 min | extended Ingress + provider scale-down (now part of Phase A below) |
| B — `terraform destroy` | ~9 min | ~30 min | one-time IAM + bucket workarounds (`platform-iac#66`, `#67`) |
| C — cloud hygiene check | <1 min | ~2 min | five PVC-backed disks to delete (now part of Phase C below) |
| D — re-bootstrap (`bootstrap.sh`) | ~15 min | ~18 min | one-time IAM-preflight + `container.admin` retries (`platform-iac#66`) |
| E — end-to-end verification | ~3 min | ~28 min | reconcile to converged state + one `prometheus-operator` restart |
| **Total** | **~30 min** | **~84 min** | one-time discoveries; reference time returns after the follow-up PRs land |

Cluster create dominates Phase D (~7 min on the reference, ~9m50s on the S4-04b run). Argo CD reconciliation dominates Phase E (cert issuance, DNS propagation, all platform Applications to Healthy).

Live evidence for the 2026-06-15 run is captured in [`platform-gitops/docs/cluster-redeploy-validation.md`](https://github.com/INENI-PT-GROUP-B/platform-gitops/blob/main/docs/cluster-redeploy-validation.md) (S4-04b, `platform-gitops#65`).

## Prerequisites

- Authenticate gcloud twice: `gcloud auth login` (CLI surface) and `gcloud auth application-default login` (Application Default Credentials, used by Terraform). The second is easy to miss; the symptom is a Phase 3 failure several minutes deep instead of a Phase 0 fail-fast.
- `bootstrap/bootstrap.env` populated (`GCP_PROJECT_ID`, `GCP_REGION`, `GCP_ZONE`, `GHCR_TOKEN`, `GRAFANA_ADMIN_PASSWORD`).
- `kubectl` configured against the cluster you want to tear down (Phase 4 of the previous bootstrap set this; verify with `kubectl config current-context`).
- Operator IAM grants on the project. The set required for a complete teardown + rebootstrap, measured during the S4-04b run:

  | Role | Why needed |
  | --- | --- |
  | `roles/editor` | baseline (resource CRUD via Terraform) |
  | `roles/resourcemanager.projectIamAdmin` | grant the other roles below to yourself |
  | `roles/iam.serviceAccountAdmin` | manage the GSAs Terraform owns |
  | `roles/iam.workloadIdentityPoolAdmin` | WI bindings for the GSAs |
  | `roles/iam.roleAdmin` | create the project custom roles (incl. the one below) |
  | `roles/serviceusage.serviceUsageAdmin` | enable required project APIs |
  | `roles/secretmanager.secretAccessor` | read GHCR + Grafana seeds from GSM |
  | `roles/dns.admin` | manage the persistent zone's records and IAM (note: does NOT include `dns.managedZones.setIamPolicy` — see custom role below) |
  | `roles/container.admin` | Argo CD's Helm chart pre-install hook needs `container.roles.delete` (not in `roles/editor`) |
  | custom `dnsZoneIamSetter` with `dns.managedZones.setIamPolicy` | tear down the per-zone IAM bindings (`roles/dns.admin` does not include this permission; `roles/owner` is blocked for external accounts by `ORG_MUST_INVITE_EXTERNAL_OWNERS`) |

  Create the custom role once per project:

  ```bash
  gcloud iam roles create dnsZoneIamSetter \
    --project=${GCP_PROJECT_ID} \
    --title="DNS Zone IAM Setter" \
    --permissions="dns.managedZones.setIamPolicy" \
    --stage=GA

  gcloud projects add-iam-policy-binding ${GCP_PROJECT_ID} \
    --member="user:${OPERATOR_EMAIL}" \
    --role="projects/${GCP_PROJECT_ID}/roles/dnsZoneIamSetter"

  # Token refresh — IAM bindings are only effective on a fresh gcloud token
  gcloud auth login --force
  gcloud auth application-default login --force
  ```

- Known issue on gcloud SDK 572.0.0+ — `bootstrap.sh` Phase 0 IAM-preflight currently calls `gcloud projects test-iam-permissions`, which does not exist on that surface (`platform-iac#66`). Until #66 lands, the script aborts in Phase 0; the workaround is to temp-comment the probe block locally, fix the prereqs by hand against the table above, and revert the edit after the run.

## Phase A — drain GitOps state

Goal: let ExternalDNS delete the records it owns (`argocd.fhuebung.lol`, `*.fhuebung.lol`, plus the matching TXT owner records) before the cluster is torn down. Otherwise those records stay in `platform-zone` and on the next bootstrap ExternalDNS will adopt and rewrite them to the new LoadBalancer IP — functional but with a brief window of resolution to a dead IP.

```bash
# 1. Stop Argo CD so it does not reconcile against the teardown
kubectl -n argocd scale deploy --all --replicas=0
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0

# 2. Stop the Crossplane providers so they do not recreate the tenant
#    Ingresses faster than ExternalDNS can prune the corresponding
#    A/TXT records.
kubectl -n crossplane-system scale deploy \
  provider-helm-* provider-kubernetes-* --replicas=0

# 3. Delete every Ingress + the LoadBalancer Service ExternalDNS owns.
#    This is the platform Argo CD Ingress, the Traefik LB Service, the
#    per-tenant Ingresses, and the Grafana Ingress.
kubectl -n argocd delete ingress argocd-server
kubectl -n traefik delete svc traefik
for ns in tenant-demotenant{1,2,3} tenant-staging monitoring; do
  kubectl -n "${ns}" delete ingress --all
done

# 4. Wait one ExternalDNS poll cycle (default 1 min) and verify
sleep 75
gcloud dns record-sets list \
  --zone=platform-zone \
  --project="${GCP_PROJECT_ID}"
# Expected: only NS and SOA remain (a transient `_acme-challenge` TXT
# may show up if cert-manager is mid-challenge — harmless).
```

If A/TXT records remain (e.g. because the ExternalDNS pod was already gone before its next poll), delete them manually with `gcloud dns record-sets delete`.

Skipping Phase A is not catastrophic — ExternalDNS reclaims its records on the next bootstrap via the `TXTOwnerID=gke-prod` marker — but it leaves a brief misresolution window and is not the clean test path.

## Phase B — `terraform destroy`

Known issue on `platform-iac` `main`: `module.backup.google_storage_bucket.pg_backups` is created without `force_destroy = true` (`platform-iac#67`). Until #67 lands, a populated bucket blocks `terraform destroy` — empty the bucket first:

```bash
gcloud storage rm -r --recursive "gs://${GCP_PROJECT_ID}-pg-backups/**"
# Backup objects are not promised to survive a teardown; see § Phase B
# Destroyed below.
```

Then run the destroy:

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

Expected: forwarding-rules / backend-services / target-pools / addresses all empty.

The disks listing usually still shows a few PVC-backed disks — one per CNPG tenant Cluster plus the cluster-wide Prometheus PVC. They were provisioned dynamically by the GKE storage driver, not by Terraform, so cluster destroy does not delete them; the next VPC + GKE create succeeds with them present, but they will collide on the next round of identical PVC names and cost storage in the meantime. Clean them up in a loop:

```bash
mapfile -t orphan_disks < <(
  gcloud compute disks list --project="${GCP_PROJECT_ID}" \
    --filter="name~^pvc-" --format="value(name)"
)
for d in "${orphan_disks[@]}"; do
  gcloud compute disks delete "${d}" \
    --zone="${GCP_ZONE}" \
    --project="${GCP_PROJECT_ID}" \
    --quiet
done
```

Anything else left over from the platform (forwarding rules pointing at deleted target pools, orphaned LB IPs) should be deleted manually before Phase D.

## Phase D — re-bootstrap

```bash
./bootstrap/bootstrap.sh
```

Phase-by-phase expectation:

- **Phase 0** — preflight passes; auth is still active from the previous session. With `platform-iac#64` merged, the operator-IAM probe also runs here and fails fast on missing permissions before any cloud work begins.
- **Phase 1** — APIs already enabled, `gcloud services enable` is a no-op.
- **Phase 1a** — shared GHCR pull-secret seed. With `GHCR_TOKEN` set to the same value as the previous bootstrap, the latest GSM version matches the rendered dockerconfigjson and no new SecretVersion is added (idempotent). With `GHCR_TOKEN` unset, the phase skips with a warn — the GSM entry from the previous bootstrap survives and tenant frontend pulls keep working.
- **Phase 1b** — Grafana admin credentials seed. Same idempotency pattern as 1a: identical `GRAFANA_ADMIN_PASSWORD` → no new version; unset → skip with warn, GSM entry persists.
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

Known-issue one-shot: the `kube-prometheus-stack` operator pod can start before the chart's CRDs are installed and then permanently miss the `Prometheus` CR. If `kubectl -n monitoring get sts prometheus-kube-prometheus-stack-prometheus` returns nothing minutes after the rest of the platform reconciles, restart the operator once:

```bash
kubectl -n monitoring rollout restart deploy/kube-prometheus-stack-operator
```

## What this run validates

- Terraform-destroy is a clean inverse of apply (no `--target` workarounds).
- The persistent zone survives and the platform reconnects to it on the next apply.
- The chain that needed manual `gcloud` workarounds during the first end-to-end run is now Terraform-managed and the cold-start path is dry: ExternalDNS gets `roles/dns.reader` from `terraform/dns/` (#43, #44) and writes records on the first poll instead of looping on 403.
- The state bucket is reused (terraform init finds the backend immediately).
- GKE cleans up its LoadBalancer artefacts on cluster destroy (Phase C).
- The operator-IAM preflight added in [`platform-iac#64`](https://github.com/INENI-PT-GROUP-B/platform-iac/pull/64) — once #66 lands and the gcloud-wrapper is replaced — runs on the real operator account and fails fast on missing permissions (or no-ops when all required roles are held).
- GSM persistence holds across teardown: the shared GHCR pull-secret entry and the Grafana admin credentials survive `terraform destroy` (GSM is outside Terraform). On rebootstrap, Phase 1a/1b either no-op with the same values or skip with a warn when the env vars are unset — the GSM entries persist regardless.
- Per-tenant BasicAuth GSM entries survive teardown by `deletionPolicy: Orphan`. Tenants previously offboarded (e.g. `tenant-deltest-*` from `platform-gitops#100`) keep their `-basicauth-htpasswd` + `-basicauth-password` GSM containers across a full cluster destroy.

## What this run does not validate

- The `roles/container.admin` README prerequisite — the operator running this teardown already holds it. Validating the prereq requires a fresh operator account or temporarily removing the role (not recommended).
