# main.tf
# Standard, zonal, VPC-native GKE cluster with Workload Identity and
# Dataplane V2. The default node pool is removed and replaced by a
# separately managed, autoscaling node pool.

# Cluster control plane. The default node pool is created then immediately
# removed so all nodes are owned by the dedicated google_container_node_pool.
resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.zone

  network    = var.network
  subnetwork = var.subnetwork

  # Remove the default node pool right after creation; nodes are managed
  # by the separate node-pool resource below.
  remove_default_node_pool = true
  initial_node_count       = 1

  # Dataplane V2 (eBPF) for networking and network policy.
  datapath_provider = "ADVANCED_DATAPATH"

  # Workload Identity: bind Kubernetes SAs to the project's identity pool.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # VPC-native cluster using the subnetwork's secondary ranges.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Default is true in provider 7.x; set false so the project can be torn
  # down and rebuilt (S4-04b) without manual intervention.
  deletion_protection = var.deletion_protection

  # Region label for cost/inventory grouping (the cluster itself is zonal).
  resource_labels = {
    region = var.region
  }
}

# Dedicated node pool: e2-standard-4 nodes, autoscaling, auto-repair and
# auto-upgrade, with the GKE Metadata Server for Workload Identity.
resource "google_container_node_pool" "primary" {
  project  = var.project_id
  name     = "${var.cluster_name}-primary"
  location = var.zone
  cluster  = google_container_cluster.this.name

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.machine_type

    # Required for Workload Identity on the nodes.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
