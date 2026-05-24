# outputs.tf
# Values consumed by the root module and, in turn, the GKE cluster module.

output "network_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.vpc.name
}

output "network_id" {
  description = "ID of the VPC network"
  value       = google_compute_network.vpc.id
}

output "network_self_link" {
  description = "Self-link of the VPC network"
  value       = google_compute_network.vpc.self_link
}

output "subnetwork_name" {
  description = "Name of the subnetwork"
  value       = google_compute_subnetwork.subnet.name
}

output "subnetwork_id" {
  description = "ID of the subnetwork"
  value       = google_compute_subnetwork.subnet.id
}

output "subnetwork_self_link" {
  description = "Self-link of the subnetwork"
  value       = google_compute_subnetwork.subnet.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range for GKE pod IPs"
  value       = var.pods_range_name
}

output "services_range_name" {
  description = "Name of the secondary range for GKE service IPs"
  value       = var.services_range_name
}
