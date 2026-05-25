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

# DNS: references the persistent public Cloud DNS managed zone for the platform
# domain (created create-if-absent by bootstrap.sh, not owned by Terraform) and
# grants the zone-scoped roles/dns.admin binding to the ExternalDNS and
# cert-manager service accounts from the IAM module.
module "dns" {
  source = "./dns"

  project_id = var.project_id

  dns_admin_service_accounts = [
    module.iam.external_dns_sa_email,
    module.iam.cert_manager_sa_email,
  ]
}

# IAM: Google Service Accounts and Workload Identity bindings for in-cluster
# platform workloads (ExternalDNS, cert-manager, ESO, Crossplane provider-gcp).
# The cluster module enables the Workload Identity pool referenced by the
# bindings; depends_on declares that ordering explicitly.
module "iam" {
  source = "./iam"

  project_id = var.project_id

  depends_on = [module.cluster]
}
