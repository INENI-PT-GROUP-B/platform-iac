# DNS Setup

This document describes the DNS configuration for the platform domain `fhuebung.lol`.

## Overview

| Item | Value |
|---|---|
| Domain | `fhuebung.lol` |
| Registrar | Porkbun |
| DNS Provider | Google Cloud DNS (native) |
| GCP Project | `dotted-axle-495612-f4` (display name: `platform-engineering-group-b`) |
| Managed Zone | `platform-zone` |
| Visibility | Public |
| DNSSEC | Off (zone and registrar) |
| Zone lifecycle | Persistent — created create-if-absent by `bootstrap.sh`, never destroyed on teardown |
| Terraform role | References the zone (data source) and manages the zone-scoped `roles/dns.admin` bindings in `terraform/dns/` |

## Provider Decision

We chose **Google Cloud DNS** over Cloudflare for the following reasons:

- Tight integration with our GKE platform via Workload Identity (no external API token needed for ExternalDNS / cert-manager)
- IAM-driven access management — no separate Cloudflare account / API-token rotation
- Single billing context (GCP project)
- Sufficient feature set for ExternalDNS (`txtOwnerId` based ownership) and cert-manager (DNS-01 challenge)

## Terraform Management

The zone is treated as **persistent infrastructure** — created and delegated once and **not** destroyed on teardown, in the same class as the Terraform state bucket and Google Secret Manager. `bootstrap.sh` creates it create-if-absent (via `gcloud`, like the state bucket) before `terraform apply`; an existing zone is reused as-is. The existing out-of-band `platform-zone` (created early to unblock NS delegation) is adopted as this persistent zone, so the nameservers already delegated at Porkbun stay valid and **no registrar step ever runs during a bootstrap**.

Because the zone is created outside Terraform, the `terraform/dns/` module references it via a `data "google_dns_managed_zone"` source rather than owning a `google_dns_managed_zone` resource. The module is composed by the root module as `module "dns"`, which feeds it the ExternalDNS and cert-manager service-account emails from the `iam` module so it can create a zone-scoped `roles/dns.admin` binding for each (Workload Identity, no static credentials). On teardown the IAM bindings are removed with the rest of the state; the zone itself survives and the bindings are recreated on the next apply.

This supersedes the earlier "recreate, not import" approach (task list S1-09). The decision is recorded in `platform/docs/claude/architecture-decisions.md` (DNS/TLS) and [platform#51](https://github.com/INENI-PT-GROUP-B/platform/issues/51); the previously planned destructive recreate plus Porkbun NS update ([platform-iac#28](https://github.com/INENI-PT-GROUP-B/platform-iac/issues/28)) is obsolete under this model. `terraform import` stays rejected, as it leaves a manual, non-reproducible step in the provisioning path.

### Zone creation parameters (for `bootstrap.sh` on an empty project)

On the current project `platform-zone` already exists, so the create-if-absent step is a no-op. On a fully empty project, `bootstrap.sh` must create the zone with these parameters **before** `terraform apply` (Terraform only references the zone, it does not create it):

| Parameter | Value |
|---|---|
| Name | `platform-zone` |
| DNS name | `fhuebung.lol.` |
| Visibility | Public |
| DNSSEC | Off |
| Description | `Public zone for the platform domain` |

Equivalent `gcloud` invocation:

```bash
gcloud dns managed-zones create platform-zone \
  --project=dotted-axle-495612-f4 \
  --dns-name=fhuebung.lol. \
  --visibility=public \
  --dnssec-state=off \
  --description="Public zone for the platform domain"
```

After creation, read the assigned nameservers and delegate them at Porkbun once (see below). On the established project this has already been done.

## Authoritative Nameservers

Google assigned four authoritative nameservers when the managed zone was created. They are delegated at Porkbun under **Authoritative Nameservers** for `fhuebung.lol`.

The persistent zone's nameservers:

```
ns-cloud-e1.googledomains.com
ns-cloud-e2.googledomains.com
ns-cloud-e3.googledomains.com
ns-cloud-e4.googledomains.com
```

> **Note:** Because the zone is persistent and never recreated, these nameservers are stable — a bootstrap run reuses the existing zone and does not change them, so no Porkbun update is needed. They would only change if the zone were deleted and created anew, which the persistent-zone model deliberately avoids. DNSSEC stays off at the registrar.

NS-record TTL is `21600s` (6h) — full global propagation can take up to 24h, but typically completes within 15 minutes to a few hours.

## Verification

Check delegation from any public resolver:

```powershell
nslookup -type=NS fhuebung.lol 8.8.8.8
nslookup -type=NS fhuebung.lol 1.1.1.1
```

Or via `dig`:

```bash
dig NS fhuebung.lol +short
whois fhuebung.lol | grep -i "name server"
```

Expected output: the four `ns-cloud-eX.googledomains.com` entries assigned to the zone.

## gcloud / Terraform commands

Read the zone's nameservers from Terraform after apply:

```bash
terraform -chdir=terraform output dns_name_servers
```

List managed zones in the active project:

```bash
gcloud dns managed-zones list --project=dotted-axle-495612-f4
```

Show zone details (incl. NS servers):

```bash
gcloud dns managed-zones describe platform-zone \
  --project=dotted-axle-495612-f4
```

List record sets in the zone:

```bash
gcloud dns record-sets list --zone=platform-zone \
  --project=dotted-axle-495612-f4
```

## Migration Notes

A previous zone existed in the legacy project `ineni-pt-group-b`. After the project switch to `dotted-axle-495612-f4`, a new zone was created out-of-band and the NS records at Porkbun were updated to the new `ns-cloud-eX` servers. That out-of-band zone is now adopted as the persistent zone (see [Terraform Management](#terraform-management)) rather than recreated, so its nameservers remain authoritative.

## Downstream Consumers

- **ExternalDNS** — manages `A` / `CNAME` records under `*.fhuebung.lol` for tenant ingresses
- **cert-manager** — solves ACME DNS-01 challenges by writing `TXT` records to the zone

Both components authenticate via Workload Identity. Their zone-scoped `roles/dns.admin` bindings are defined in the `dns/` module and wired from the `iam` module by the root module (no separate manual IAM step).
