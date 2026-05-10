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

## Provider Decision

We chose **Google Cloud DNS (Pfad A)** over Cloudflare for the following reasons:

- Tight integration with our GKE platform via Workload Identity (no external API token needed for ExternalDNS / cert-manager)
- IAM-driven access management — no separate Cloudflare account / API-token rotation
- Single billing context (GCP project)
- Sufficient feature set for ExternalDNS (`txtOwnerId` based ownership) and cert-manager (DNS-01 challenge)

## Authoritative Nameservers

The Google-managed nameservers for `platform-zone`:

```
ns-cloud-e1.googledomains.com
ns-cloud-e2.googledomains.com
ns-cloud-e3.googledomains.com
ns-cloud-e4.googledomains.com
```

These are configured at Porkbun under **Authoritative Nameservers** for `fhuebung.lol`.

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

Expected output: the four `ns-cloud-eX.googledomains.com` entries.

NS-record TTL is `21600s` (6h) — full global propagation can take up to 24h, but typically completes within 15 minutes to a few hours.

## gcloud Commands

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

A previous zone existed in the legacy project `ineni-pt-group-b`. After the project switch to `dotted-axle-495612-f4`, a new zone was created and the NS-records at Porkbun were updated to the new `ns-cloud-eX` servers. The legacy zone will be deleted once full propagation is confirmed.

## Sprint 2 — OpenTofu Import

The zone was created manually to unblock NS-delegation early. When the IaC code for DNS is added in Sprint 2, the existing zone must be imported instead of recreated:

```bash
tofu import google_dns_managed_zone.platform_zone \
  projects/dotted-axle-495612-f4/managedZones/platform-zone
```

## Downstream Consumers

- **ExternalDNS** — will manage `A` / `CNAME` records under `*.fhuebung.lol` for tenant ingresses
- **cert-manager** — will solve ACME DNS-01 challenges by writing `TXT` records to the zone

Both components require IAM bindings on the zone (`roles/dns.admin` scoped to the zone resource); these will be provisioned in Sprint 2 IaC.
