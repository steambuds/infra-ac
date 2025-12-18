# Project Configuration
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "asia-south1-a"
}

# Network Configuration
variable "vpc_name" {
  description = "Name of the VPC network"
  type        = string
  default     = "sb-vpc"
}

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "sb-subnet"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/24"
}

# Cluster Configuration
variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "sb-cluster"
}

# Safe Node Pool Configuration (Always-on nodes for databases)
variable "safe_pool_name" {
  description = "Name of the safe node pool"
  type        = string
  default     = "sb-safe-pool"
}

variable "safe_pool_machine_type" {
  description = "Machine type for safe pool nodes."
  type        = string
  default     = "e2-small"
}

variable "safe_pool_disk_size" {
  description = "Disk size in GB for safe pool nodes"
  type        = number
  default     = 30
}

variable "safe_pool_node_count" {
  description = "Number of nodes in safe pool (should be 1 for budget)"
  type        = number
  default     = 1
}

# Spot Node Pool Configuration (Preemptible nodes for stateless workloads)
variable "spot_pool_name" {
  description = "Name of the spot node pool"
  type        = string
  default     = "sb-spot-pool"
}

variable "spot_pool_machine_type" {
  description = "Machine type for spot pool nodes"
  type        = string
  default     = "e2-medium"
}

variable "spot_pool_min_nodes" {
  description = "Minimum number of nodes in spot pool (0 to save costs when idle)"
  type        = number
  default     = 0
}

variable "spot_pool_max_nodes" {
  description = "Maximum number of nodes in spot pool"
  type        = number
  default     = 5
}

# Resource Labels for cost tracking
variable "labels" {
  description = "Labels to apply to all resources for cost tracking and organization"
  type        = map(string)
  default = {
    project     = "steambuds"
    environment = "dev"
    managed_by  = "terraform"
    cost_center = "engineering"
  }
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod])"
  type        = string
  default     = "dev"
}
