# outputs.tf
# Root outputs. The secondary-range names feed the GKE cluster module's
# ip_allocation_policy (VPC-native).

output "network_name" {
  description = "Name of the platform VPC network"
  value       = module.network.network_name
}

output "subnetwork_name" {
  description = "Name of the platform subnetwork"
  value       = module.network.subnetwork_name
}

output "subnetwork_self_link" {
  description = "Self-link of the platform subnetwork"
  value       = module.network.subnetwork_self_link
}

output "pods_range_name" {
  description = "Secondary range name for GKE pod IPs"
  value       = module.network.pods_range_name
}

output "services_range_name" {
  description = "Secondary range name for GKE service IPs"
  value       = module.network.services_range_name
}
