# variables.tf
# Input variables for the GKE cluster module.

variable "project_id" {
  description = "The GCP project ID that owns the cluster"
  type        = string
}

variable "region" {
  description = "The GCP region (provider context for the cluster)"
  type        = string
}

variable "zone" {
  description = "The GCP zone for this zonal cluster and its node pool"
  type        = string
  default     = "europe-west1-b"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "platform-cluster"
}

variable "network" {
  description = "Name of the VPC network to attach the cluster to"
  type        = string
}

variable "subnetwork" {
  description = "Name of the subnetwork to attach the cluster to"
  type        = string
}

variable "pods_range_name" {
  description = "Name of the subnetwork secondary range for GKE pod IPs"
  type        = string
}

variable "services_range_name" {
  description = "Name of the subnetwork secondary range for GKE service IPs"
  type        = string
}

variable "machine_type" {
  description = "Compute Engine machine type for the node pool"
  type        = string
  default     = "e2-standard-4"
}

variable "min_node_count" {
  description = "Minimum number of nodes for node-pool autoscaling"
  type        = number
  default     = 3
}

variable "max_node_count" {
  description = "Maximum number of nodes for node-pool autoscaling"
  type        = number
  default     = 6
}

variable "deletion_protection" {
  description = "Block terraform destroy of the cluster. False allows teardown/rebuild (S4-04b)."
  type        = bool
  default     = false
}
