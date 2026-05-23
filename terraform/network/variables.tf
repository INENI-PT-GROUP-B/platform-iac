# variables.tf
# Input variables for the network module.

variable "project_id" {
  description = "The GCP project ID that owns the network resources"
  type        = string
}

variable "region" {
  description = "The GCP region for the subnetwork"
  type        = string
}

variable "network_name" {
  description = "Name of the custom-mode VPC network"
  type        = string
  default     = "platform-vpc"
}

variable "subnet_name" {
  description = "Name of the subnetwork"
  type        = string
  default     = "platform-subnet"
}

variable "subnet_cidr" {
  description = "Primary IPv4 CIDR range for the subnetwork (node IPs)"
  type        = string
  default     = "10.10.0.0/24"
}

variable "pods_range_name" {
  description = "Name of the secondary range used for GKE pod IPs"
  type        = string
  default     = "pods"
}

variable "pods_cidr" {
  description = "Secondary IPv4 CIDR range for GKE pod IPs"
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_range_name" {
  description = "Name of the secondary range used for GKE service IPs"
  type        = string
  default     = "services"
}

variable "services_cidr" {
  description = "Secondary IPv4 CIDR range for GKE service IPs"
  type        = string
  default     = "10.30.0.0/20"
}
