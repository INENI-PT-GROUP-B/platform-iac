# Day-1 Platform End-to-End Validation

Smoke test exercising the Day-1 platform stack (cert-manager, ExternalDNS, ESO, Traefik) through a minimal test workload. Closes `INENI-PT-GROUP-B/platform-gitops#23`.

## Scope

The Day-1 stack is considered validated when, on a cluster brought up by `bootstrap.sh` and reconciled by Argo CD against `platform-gitops` on `main`:

1. A new public Ingress under `*.fhuebung.lol` returns HTTPS 200 with a Let's Encrypt certificate.
2. The matching DNS record in Cloud DNS is created automatically by ExternalDNS.
3. A secret seeded in Google Secret Manager appears as a Kubernetes Secret in the cluster, synced by ESO.

Out of scope: Day-2 tenant onboarding, Crossplane Compositions, the monitoring stack (S4-01 bonus).

## Method

The test fixtures live in [`validation-day1/`](./validation-day1/) — see the [README](./validation-day1/README.md) for an overview.

### Prerequisites

A cluster reconciled to the post-bootstrap "all twelve children Healthy" state (per [`TEARDOWN.md`](./TEARDOWN.md) Phase E). The operator's `kubectl` context points at this cluster and `gcloud config project` is `dotted-axle-495612-f4`.

### Seed the GSM source secret

```bash
echo -n 'gitops-23-validation-payload' | gcloud secrets create validation-day1-test \
  --replication-policy=automatic --data-file=- --project=dotted-axle-495612-f4
```

### Deploy the test workload

```bash
kubectl apply -f validation-day1/
```

Wait briefly until the ExternalSecret reports `Ready=True` and the Ingress address is populated — typically under 30s in practice. A `kubectl wait` call returns within ~1s once the platform has been live for a while, so explicit polling is rarely needed.

## Results — 2026-06-01

Run on the cluster baseline established by mr's teardown + re-bootstrap on 2026-05-30 (per [`TEARDOWN.md`](./TEARDOWN.md) Phase E). Operator: `rl770bl@gmail.com`. `gcloud config project = dotted-axle-495612-f4`.

### AC1 — HTTPS 200 with a valid Let's Encrypt certificate

```text
$ curl -sS -o /dev/null -w 'HTTP %{http_code}  TLS-verify %{ssl_verify_result}\n' https://hello.fhuebung.lol/
HTTP 200  TLS-verify 0

$ curl -sI https://hello.fhuebung.lol/ | head -5
HTTP/2 200
accept-ranges: bytes
content-type: text/html
date: Mon, 01 Jun 2026 20:54:08 GMT
etag: "6a1df133-7b"

$ openssl s_client -connect hello.fhuebung.lol:443 -servername hello.fhuebung.lol </dev/null 2>/dev/null \
    | openssl x509 -noout -issuer -subject -dates
issuer=C = US, O = Let's Encrypt, CN = YR1
subject=CN = *.fhuebung.lol
notBefore=May 31 13:36:02 2026 GMT
notAfter=Aug 29 13:36:01 2026 GMT
```

Pass criterion: `HTTP/2 200`, issuer contains `Let's Encrypt`, subject `CN=*.fhuebung.lol` (wildcard covers `hello.fhuebung.lol`), `notAfter` in the future. **All met.**

### AC2 — ExternalDNS auto-created DNS record

```text
$ gcloud dns record-sets list --zone=platform-zone --project=dotted-axle-495612-f4 \
    | grep -E 'hello|\*\.fhuebung|^NAME'
NAME                    TYPE  TTL    DATA
*.fhuebung.lol.         A     300    34.79.103.36
a-*.fhuebung.lol.       TXT   300    "heritage=external-dns,external-dns/owner=gke-prod,external-dns/resource=service/traefik/traefik"
a-hello.fhuebung.lol.   TXT   300    "heritage=external-dns,external-dns/owner=gke-prod,external-dns/resource=ingress/validation-day1/hello"
hello.fhuebung.lol.     A     300    34.79.103.36

$ dig +short hello.fhuebung.lol
34.79.103.36
```

The first two rows are platform baseline — ExternalDNS owns the `*.fhuebung.lol` wildcard via the Traefik Service's `external-dns.alpha.kubernetes.io/hostname` annotation. The AC2-relevant rows are the bottom two: a host-specific `A` for `hello.fhuebung.lol.` resolving to the Traefik LoadBalancer IP, and the matching TXT-owner marker that names `ingress/validation-day1/hello` as the source. ExternalDNS actively created a host-specific record from this test Ingress, not just passive wildcard coverage. Pass criterion met.

### AC3 — ESO round-trip from GSM

Seed (sent literal payload via stdin to `gcloud secrets create`):

```text
$ echo -n 'gitops-23-validation-payload' | gcloud secrets create validation-day1-test \
    --replication-policy=automatic --data-file=- --project=dotted-axle-495612-f4
Created version [1] of the secret [validation-day1-test].
```

ExternalSecret status (captured as part of a broader namespace state check — relevant lines reproduced below):

```text
$ kubectl -n validation-day1 get all,externalsecret,ingress,secret
...
NAME                                                  STORETYPE            STORE                REFRESH INTERVAL   STATUS         READY   LAST SYNC
externalsecret.external-secrets.io/eso-test-payload   ClusterSecretStore   gcp-secret-manager   1m                 SecretSynced   True    32s
...
NAME                      TYPE     DATA   AGE
secret/eso-test-payload   Opaque   1      2m32s
```

K8s-side decoded payload:

```text
$ kubectl -n validation-day1 get secret eso-test-payload -o jsonpath='{.data.value}' | base64 -d
gitops-23-validation-payload
```

Pass criterion: the seeded payload (`gitops-23-validation-payload`) and the K8s-side decoded payload are byte-identical. **Met.**

Sidenote — direct GSM read from the operator's identity is denied:

```text
$ gcloud secrets versions access latest --secret=validation-day1-test --project=dotted-axle-495612-f4
ERROR: (gcloud.secrets.versions.access) PERMISSION_DENIED: Permission 'secretmanager.versions.access' denied on resource (or it may not exist). This command is authenticated as rl770bl@gmail.com which is the active account specified by the [core/account] property.
- '@type': type.googleapis.com/google.rpc.ErrorInfo
  domain: iam.googleapis.com
  metadata:
    permission: secretmanager.versions.access
  reason: IAM_PERMISSION_DENIED
```

This is the intended posture: the operator can create secrets (`secretmanager.admin` via `roles/editor` + `roles/iam.serviceAccountAdmin`) but cannot read versions. ESO reads via the `external-secrets@dotted-axle-495612-f4.iam.gserviceaccount.com` GSA, bound through GKE Workload Identity. The round-trip therefore also confirms the least-privilege WI binding is functional.

### AC4 — Cleanup

```bash
kubectl delete namespace validation-day1
gcloud secrets delete validation-day1-test --project=dotted-axle-495612-f4 --quiet
```

Post-cleanup verification (run immediately after the delete commands — ExternalDNS removed the records before the next query, so no explicit wait was needed):

```text
$ kubectl get ns validation-day1
Error from server (NotFound): namespaces "validation-day1" not found

$ gcloud secrets describe validation-day1-test --project=dotted-axle-495612-f4
ERROR: (gcloud.secrets.describe) NOT_FOUND: Secret [projects/519758945793/secrets/validation-day1-test] not found. This command is authenticated as rl770bl@gmail.com which is the active account specified by the [core/account] property.

$ gcloud dns record-sets list --zone=platform-zone --project=dotted-axle-495612-f4 | grep -E 'hello|^NAME'
NAME                    TYPE  TTL    DATA
```

The DNS grep returns only the header — no rows matching `hello` remain. All three traces gone. ExternalDNS removed the A and TXT records on Ingress deletion because the chart runs with `policy: sync`. The TXT-owner marker is what gates this — only records ExternalDNS owns are removed; pre-existing manual records would be left alone.

## Result

**Pass.** All four ACs met with the evidence captured above on 2026-06-01.

The four assertions taken together prove the Day-1 platform end-to-end: cert-manager issues a valid wildcard from Let's Encrypt, Traefik terminates TLS with it for a fresh subdomain, ExternalDNS publishes the matching A record into Cloud DNS with an owner marker, and ESO synchronises a Google Secret Manager entry into a Kubernetes Secret via Workload Identity — all without any per-tenant manual step or operator GCP credential beyond the standard `gcloud auth` session.

## Reproducing

The manifests under `validation-day1/` plus the commands above are sufficient to re-run the validation on any future bootstrap. Estimated wallclock: ~3 min from `kubectl apply` to all assertions green — matches `TEARDOWN.md` Phase E.
