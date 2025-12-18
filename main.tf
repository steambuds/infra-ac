terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.14.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# 1. GCS Bucket for Terraform State
resource "google_storage_bucket" "terraform_state" {
  name          = "${var.project_id}-tf-state"
  location      = var.region
  force_destroy = false # Prevent accidental deletion

  uniform_bucket_level_access = true

  versioning {
    enabled = true # Keep history of state files
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(
    var.labels,
    {
      purpose = "terraform-state"
    }
  )
}

# 2. GCS Bucket for Database Backups
resource "google_storage_bucket" "db_backups" {
  name          = "${var.project_id}-db-backups"
  location      = var.region
  force_destroy = false # Prevent accidental deletion

  uniform_bucket_level_access = true

  versioning {
    enabled = true # Keep backup history
  }

  lifecycle_rule {
    condition {
      age = 30 # Delete backups older than 30 days
    }
    action {
      type = "Delete"
    }
  }

  labels = merge(
    var.labels,
    {
      purpose = "database-backups"
    }
  )
}

# 3. VPC Network (The Private Cloud)
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
}

# 4. Subnet with Secondary IP Ranges for Pods and Services
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnet_name
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = var.subnet_cidr

  # Secondary ranges to avoid IP conflicts
  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.1.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.2.0.0/16"
  }
}

# 5. Firewall: Allow Internal Communication
resource "google_compute_firewall" "internal" {
  name    = "allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  # Trust traffic from inside our network
  source_ranges = ["10.0.0.0/24", "10.1.0.0/16", "10.2.0.0/16"]
}

# 6. Firewall: Allow GKE Master to Node Communication
resource "google_compute_firewall" "gke_master" {
  name    = "allow-gke-master"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["443", "10250", "8443"]
  }

  # GKE master IP range (will be auto-assigned)
  source_ranges = ["172.16.0.0/28"]
  target_tags   = ["postgres", "database", "db", "sb", "server", "web"]
}

# 7. Firewall: Allow Egress for Docker Images and External APIs
resource "google_compute_firewall" "egress" {
  name      = "allow-egress"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  destination_ranges = ["0.0.0.0/0"]
}

# 8. Firewall: Allow Health Checks from Google
resource "google_compute_firewall" "health_checks" {
  name    = "allow-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  # Google Cloud health checker IP ranges
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["sb", "server", "web"]
}

# 9. GKE Cluster (The Brain)
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone # Zonal = Free Control Plane

  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.vpc.name
  subnetwork               = google_compute_subnetwork.subnet.name

  # Resource labels for cost tracking
  resource_labels = var.labels

  # Native VPC networking for better performance
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  # Workload Identity (Securely access Google APIs)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Network Policy for pod-to-pod security
  network_policy {
    enabled = true
  }

  # Enable logging for troubleshooting
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Enable monitoring
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  # Control when updates happen
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00" # 3 AM IST
    }
  }
}

# 10. Safe Node Pool (Always On - For Database)
resource "google_container_node_pool" "safe_pool" {
  name       = var.safe_pool_name
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.safe_pool_node_count

  node_config {
    machine_type = var.safe_pool_machine_type
    disk_size_gb = var.safe_pool_disk_size
    tags         = ["postgres", "database", "db"]
    spot         = false # Keep this alive!

    labels = merge(
      var.labels,
      {
        role     = "safe-node"
        nodepool = var.safe_pool_name
      }
    )

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Enable Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# 11. Spot Node Pool (Scalable - For Application)
resource "google_container_node_pool" "spot_pool" {
  name     = var.spot_pool_name
  location = var.zone
  cluster  = google_container_cluster.primary.name

  autoscaling {
    min_node_count = var.spot_pool_min_nodes
    max_node_count = var.spot_pool_max_nodes
  }

  node_config {
    machine_type = var.spot_pool_machine_type
    spot         = true # Preemptible for cost savings

    labels = merge(
      var.labels,
      {
        role     = "worker-node"
        nodepool = var.spot_pool_name
      }
    )

    tags = ["sb", "server", "web"]

    # Taint Syntax (Google Provider uses NO_SCHEDULE)
    taint {
      key    = "instance_type"
      value  = "spot"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Enable Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# 12. Service Account for Backups
resource "google_service_account" "backup_sa" {
  account_id   = "db-backup-sa"
  display_name = "Database Backup Service Account"
}

# 13. Grant Storage Admin to Backup SA
resource "google_storage_bucket_iam_member" "backup_sa_permissions" {
  bucket = "${var.project_id}-db-backups"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.backup_sa.email}"
}

# 14. Bind GCP SA to Kubernetes SA via Workload Identity
resource "google_service_account_iam_member" "backup_workload_identity" {
  service_account_id = google_service_account.backup_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[default/backup-sa]"
}