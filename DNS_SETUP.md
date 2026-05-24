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
| Management | Terraform — `terraform/dns/` module, wired into the root module |

## Provider Decision

We chose **Google Cloud DNS** over Cloudflare for the following reasons:

- Tight integration with our GKE platform via Workload Identity (no external API token needed for ExternalDNS / cert-manager)
- IAM-driven access management — no separate Cloudflare account / API-token rotation
- Single billing context (GCP project)
- Sufficient feature set for ExternalDNS (`txtOwnerId` based ownership) and cert-manager (DNS-01 challenge)

## Terraform Management

The zone is defined in code in the `terraform/dns/` module and composed by the root module as `module "dns"`. The root module also feeds the module the ExternalDNS and cert-manager service-account emails from the `iam` module, so the module creates a zone-scoped `roles/dns.admin` binding for each (Workload Identity, no static credentials).

The zone is **created fresh by Terraform** during `bootstrap.sh` — it is **not** imported. We deliberately avoid `terraform import`: importing leaves a manual, non-reproducible step in the provisioning path and breaks the one-command bootstrap promise — a clean run on an empty project must create the zone itself. The out-of-band zone (created early to unblock NS delegation) holds no records we need to preserve, so a delete-and-recreate is safe.

The coordinated, destructive delete-and-recreate of the existing zone, plus the follow-up Porkbun nameserver update, is an operational step (it needs `gcloud` and registrar access during a bootstrap run), tracked separately in [issue #28](https://github.com/INENI-PT-GROUP-B/platform-iac/issues/28). Until that run happens, the live delegation still points at the out-of-band zone's nameservers listed below.

## Authoritative Nameservers

Google assigns four authoritative nameservers when the managed zone is created. They are delegated at Porkbun under **Authoritative Nameservers** for `fhuebung.lol`.

The nameservers of the current out-of-band zone:

```
ns-cloud-e1.googledomains.com
ns-cloud-e2.googledomains.com
ns-cloud-e3.googledomains.com
ns-cloud-e4.googledomains.com
```

> **Note:** The Terraform recreate provisions a fresh zone, for which Google may assign a **different** nameserver set. After the recreate, read the new servers (see [gcloud / Terraform commands](#gcloud--terraform-commands)) and update them at Porkbun if they differ. DNSSEC stays off at the registrar.

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

A previous zone existed in the legacy project `ineni-pt-group-b`. After the project switch to `dotted-axle-495612-f4`, a new zone was created out-of-band and the NS records at Porkbun were updated to the new `ns-cloud-eX` servers. That out-of-band zone is the one the Terraform recreate replaces (see [Terraform Management](#terraform-management)).

## Downstream Consumers

- **ExternalDNS** — manages `A` / `CNAME` records under `*.fhuebung.lol` for tenant ingresses
- **cert-manager** — solves ACME DNS-01 challenges by writing `TXT` records to the zone

Both components authenticate via Workload Identity. Their zone-scoped `roles/dns.admin` bindings are defined in the `dns/` module and wired from the `iam` module by the root module (no separate manual IAM step).
