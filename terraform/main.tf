# main.tf
# Root module: composes the per-concern child modules.

# Network: VPC, subnet (with GKE secondary ranges), and baseline firewall.
module "network" {
  source = "./network"

  project_id = var.project_id
  region     = var.region
}
