# variables.tf
# Declares all input variables for the Terraform configuration

variable "project_id" {
  description = "The GCP project ID where resource will be provisioned"
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources into"
  type        = string
  default     = "europe-west1"
}