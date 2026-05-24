# main.tf
# Root module: composes the per-concern child modules.

# Network: VPC, subnet (with GKE secondary ranges), and baseline firewall.
module "network" {
  source = "./network"

  project_id = var.project_id
  region     = var.region
}

# Cluster: standard, zonal, VPC-native GKE cluster with Workload Identity.
module "cluster" {
  source = "./cluster"

  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  network             = module.network.network_name
  subnetwork          = module.network.subnetwork_name
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
}
