# main.tf
# VPC, subnetwork (with GKE secondary ranges), and a baseline firewall rule.

# Custom-mode VPC: subnets are declared explicitly, never auto-created.
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Regional subnetwork with secondary ranges for VPC-native GKE (pods, services).
resource "google_compute_subnetwork" "subnet" {
  project       = var.project_id
  name          = var.subnet_name
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Let nodes reach Google APIs over internal IPs without public egress.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = var.pods_range_name
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = var.services_range_name
    ip_cidr_range = var.services_cidr
  }
}

# Baseline east-west rule: allow traffic between resources inside the VPC
# (subnet, pod, and service ranges). GKE manages its own cluster and
# LoadBalancer firewall rules separately.
resource "google_compute_firewall" "allow_internal" {
  project   = var.project_id
  name      = "${var.network_name}-allow-internal"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"

  source_ranges = [
    var.subnet_cidr,
    var.pods_cidr,
    var.services_cidr,
  ]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}
