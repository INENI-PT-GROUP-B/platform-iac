# Day-1 E2E Validation Manifests

Minimal test artefacts used by the Day-1 platform end-to-end validation. Applied
manually with `kubectl apply -f validation-day1/` against a running cluster after a
`bootstrap.sh` run; not part of Argo CD's reconciled scope (Argo CD does not
watch this repository).

See [`../VALIDATION.md`](../VALIDATION.md) for the full procedure and the
captured evidence.

## Files

| File | Purpose |
|---|---|
| `00-namespace.yaml` | Namespace `validation-day1` |
| `01-hello-app.yaml` | nginx Deployment + Service + ConfigMap (static "hello" page) |
| `02-hello-ingress.yaml` | Ingress on `hello.fhuebung.lol` via Traefik (wildcard TLS) |
| `03-external-secret.yaml` | ExternalSecret pulling `validation-day1-test` from GSM |

## One-shot

Assuming `cwd` is `platform-iac/`:

```bash
# Seed the GSM source secret (replace value with anything identifying)
echo -n 'gitops-23-validation-payload' | gcloud secrets create validation-day1-test \
  --replication-policy=automatic --data-file=- --project=dotted-axle-495612-f4

kubectl apply -f validation-day1/
```

## Cleanup

```bash
kubectl delete namespace validation-day1
gcloud secrets delete validation-day1-test --project=dotted-axle-495612-f4 --quiet
```
