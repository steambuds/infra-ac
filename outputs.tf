# Cluster Outputs
output "cluster_name" {
  description = "Name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "Endpoint for the GKE cluster"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_location" {
  description = "Location of the GKE cluster"
  value       = google_container_cluster.primary.location
}

output "cluster_ca_certificate" {
  description = "CA certificate for the GKE cluster"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# Network Outputs
output "vpc_name" {
  description = "Name of the VPC network"
  value       = google_compute_network.vpc.name
}

output "vpc_id" {
  description = "ID of the VPC network"
  value       = google_compute_network.vpc.id
}

output "subnet_name" {
  description = "Name of the subnet"
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_cidr" {
  description = "CIDR range of the subnet"
  value       = google_compute_subnetwork.subnet.ip_cidr_range
}

# Node Pool Outputs
output "safe_pool_name" {
  description = "Name of the safe node pool"
  value       = google_container_node_pool.safe_pool.name
}

output "spot_pool_name" {
  description = "Name of the spot node pool"
  value       = google_container_node_pool.spot_pool.name
}

# kubectl Configuration Command
output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone=${google_container_cluster.primary.location} --project=${var.project_id}"
}

# Cost Estimation
output "estimated_monthly_cost" {
  description = "Estimated monthly cost breakdown (approximate)"
  value = <<-EOT
    Cost Breakdown (Approximate):
    - GKE Control Plane (Zonal): $0
    - Safe Pool (${var.safe_pool_machine_type}): ~$${var.safe_pool_machine_type == "e2-micro" ? "6.50" : var.safe_pool_machine_type == "e2-small" ? "13" : "26"}/mo
    - Spot Pool (${var.spot_pool_machine_type}, when active): ~$${var.spot_pool_machine_type == "e2-small" ? "3.50" : var.spot_pool_machine_type == "e2-medium" ? "7" : "14"}/mo
    - Persistent Disks: Variable based on size
    - Egress Traffic: Variable based on usage

    Total Base Cost: ~$${var.safe_pool_machine_type == "e2-micro" ? "6.50" : var.safe_pool_machine_type == "e2-small" ? "13" : "26"}-$${tonumber(var.safe_pool_machine_type == "e2-micro" ? "6.50" : var.safe_pool_machine_type == "e2-small" ? "13" : "26") + tonumber(var.spot_pool_machine_type == "e2-small" ? "3.50" : var.spot_pool_machine_type == "e2-medium" ? "7" : "14")}/month
  EOT
}

# Resource Labels
output "resource_labels" {
  description = "Labels applied to all resources"
  value       = var.labels
}
