# variables.tf
# Input variables for the iam module.
#
# Each in-cluster workload that needs GCP API access gets a dedicated
# Google Service Account (GSA) plus a Workload Identity binding to a
# Kubernetes Service Account (KSA). KSA names and namespaces default to
# the upstream Helm-chart conventions and are exposed as variables so the
# bindings can be retargeted without code changes if a chart override
# moves a workload.

variable "project_id" {
  description = "The GCP project ID that owns the service accounts and IAM bindings"
  type        = string
}

# --- ExternalDNS ---

variable "external_dns_sa_id" {
  description = "Account ID (email prefix) for the ExternalDNS Google Service Account"
  type        = string
  default     = "external-dns"
}

variable "external_dns_ksa_name" {
  description = "Kubernetes Service Account name used by ExternalDNS"
  type        = string
  default     = "external-dns"
}

variable "external_dns_namespace" {
  description = "Kubernetes namespace where ExternalDNS runs"
  type        = string
  default     = "external-dns"
}

# --- cert-manager ---

variable "cert_manager_sa_id" {
  description = "Account ID (email prefix) for the cert-manager Google Service Account"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_ksa_name" {
  description = "Kubernetes Service Account name used by cert-manager"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_namespace" {
  description = "Kubernetes namespace where cert-manager runs"
  type        = string
  default     = "cert-manager"
}

# --- External Secrets Operator (ESO) ---

variable "external_secrets_sa_id" {
  description = "Account ID (email prefix) for the External Secrets Operator Google Service Account"
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_ksa_name" {
  description = "Kubernetes Service Account name used by External Secrets Operator"
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_namespace" {
  description = "Kubernetes namespace where External Secrets Operator runs"
  type        = string
  default     = "external-secrets"
}

# --- Crossplane provider-gcp ---

variable "crossplane_provider_gcp_sa_id" {
  description = "Account ID (email prefix) for the Crossplane provider-gcp Google Service Account"
  type        = string
  default     = "crossplane-provider-gcp"
}

variable "crossplane_provider_gcp_ksa_name" {
  description = "Kubernetes Service Account name used by Crossplane provider-gcp (matches the DeploymentRuntimeConfig set in S2-10)"
  type        = string
  default     = "provider-gcp"
}

variable "crossplane_namespace" {
  description = "Kubernetes namespace where Crossplane and its providers run"
  type        = string
  default     = "crossplane-system"
}
