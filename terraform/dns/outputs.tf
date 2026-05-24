# outputs.tf
# Values consumed by the root module and downstream platform components
# (ExternalDNS, cert-manager) once those are wired.

output "zone_name" {
  description = "Name of the Cloud DNS managed zone"
  value       = google_dns_managed_zone.platform.name
}

output "dns_name" {
  description = "Fully-qualified DNS name of the zone (with trailing dot)"
  value       = google_dns_managed_zone.platform.dns_name
}

output "name_servers" {
  description = "Google-assigned authoritative nameservers for the zone (set at the registrar)"
  value       = google_dns_managed_zone.platform.name_servers
}

output "zone_id" {
  description = "Identifier of the managed zone"
  value       = google_dns_managed_zone.platform.id
}
