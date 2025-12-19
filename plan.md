This is your **Master Execution Plan**. It incorporates every security fix, cost optimization, and best practice we discussed.

**Follow this order strictly.** Do not skip steps, especially the "Manual" ones (like creating buckets or secrets), or the automation will fail.

---

## **Phase 0: The One-Time Setup (Do this Manually)** ✅ COMPLETED

Before writing code, we must prepare the environment.

### 1. Install Tools

Ensure you have `gcloud`, `terraform`, `kubectl`, and `cloudflared` installed.

### 2. Authenticate

```bash
gcloud auth login
gcloud auth application-default login
```

### 3. Create Your Configuration File

**Create a `.env` file from the template:**

```bash
# Copy the example file
cp .env.example .env

# Edit .env with your actual values
nano .env  # or use your preferred editor
```

**Your `.env` file should look like:**
```bash
PROJECT_ID="your-actual-project-id"
REGION="asia-south1"
ZONE="asia-south1-a"
BILLING_ACCOUNT_ID="your-billing-account-id"  # Optional
CLUSTER_NAME="sb-cluster"
DB_PASSWORD="YourSuperSecurePassword123!"
# CLOUDFLARE_TUNNEL_TOKEN will be added later
GITHUB_USER="your-github-username"
GITHUB_REPO="your-repo-name"
```

**Load the configuration (Option 1 - Using helper script):**

```bash
# Use the provided setup script (recommended)
source setup.sh
```

**Or load manually (Option 2):**

```bash
# Source the .env file to load variables

source .env

# Set the GCP project
gcloud config set project $PROJECT_ID
```

**Note:** The `.env` file is in `.gitignore` so it won't be committed to git. This keeps your secrets safe!

**Pro Tip:** Add this to your shell profile to auto-load when you enter the directory:
```bash
# Add to ~/.bashrc or ~/.zshrc
if [ -f .env ]; then source .env; fi
```

### 4. Enable Required GCP APIs

**CRITICAL: Without these, nothing will work.**

```bash
gcloud services enable compute.googleapis.com
gcloud services enable container.googleapis.com
gcloud services enable storage.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
```

### 5. Configure Terraform Variables

**Create a `terraform.tfvars` file from the template:**

```bash
cp terraform.tfvars.example terraform.tfvars

# Edit with your actual values
nano terraform.tfvars
```

This file will override the defaults in `variables.tf` and is gitignored for security.

**Alternatively**, Terraform will automatically use values from your environment variables if they match the pattern `TF_VAR_<variable_name>`:

```bash
# Example: Set terraform variables from .env
export TF_VAR_project_id=$PROJECT_ID
export TF_VAR_region=$REGION
export TF_VAR_zone=$ZONE
```

---

## **Phase 1: Infrastructure (The Foundation)** ✅ COMPLETED

Create the complete infrastructure with all security and monitoring features.

### Bootstrap Process (Important!)

Since Terraform needs to create the bucket that stores its own state, we use a two-step process:

**Step 1: Initial Setup (Local State)**
```bash
# Comment out the backend block in backend.tf temporarily
# Or simply don't create backend-config.tfbackend yet

terraform init
terraform apply  # Creates both GCS buckets
```

**Step 2: Migrate to Remote State**
```bash
# Create backend configuration
cp backend-config.tfbackend.example backend-config.tfbackend
nano backend-config.tfbackend  # Add your bucket name

# Reinitialize with backend
terraform init -backend-config=backend-config.tfbackend -migrate-state

# Type 'yes' when prompted to migrate state
```

**What This Does:**
1. First `terraform apply` creates the buckets using local state (stored in current directory)
2. `terraform init -migrate-state` moves the state file from local to GCS
3. Future changes are tracked in GCS with versioning enabled

**File: `terraform/main.tf`**

```hcl
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
  force_destroy = false

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }
}

# 2. GCS Bucket for Database Backups
resource "google_storage_bucket" "db_backups" {
  name          = "${var.project_id}-db-backups"
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 30  # Delete backups older than 30 days
    }
    action {
      type = "Delete"
    }
  }
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
  location = var.zone  # Zonal = Free Control Plane

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
      start_time = "03:00"  # 3 AM IST
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
    spot         = false  # Keep this alive!

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
    spot         = true  # Preemptible for cost savings

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
```

### Execute Phase 1

**Initial deployment (local state):**
```bash
terraform init
terraform plan    # Review what will be created
terraform apply   # Type 'yes' when prompted
```

**This creates:**
- Both GCS buckets (state + backups)
- VPC network and subnets
- Firewall rules
- GKE cluster and node pools
- Service accounts

**Migrate to remote state:**
```bash
# Create backend config
cp backend-config.tfbackend.example backend-config.tfbackend
nano backend-config.tfbackend  # Set bucket = "your-project-id-tf-state"

# Migrate state to GCS
terraform init -backend-config=backend-config.tfbackend -migrate-state
# Type 'yes' when prompted
```

**Verify migration:**
```bash
# Check that state is now in GCS
gsutil ls gs://$PROJECT_ID-tf-state/terraform/state/
```

### Connect kubectl to Your Cluster

install the 
```bash
  gcloud components install gke-gcloud-auth-plugin
```

**IMPORTANT: Use --zone not --region for zonal clusters**
```bash
gcloud container clusters get-credentials sb-cluster \
  --zone=asia-south1-a \
  --project=$PROJECT_ID
```

Verify connection:
```bash
kubectl get nodes -o wide
or 
kubectl get nodes
```

---

## **Phase 2: Database Layer (Secure & Persistent)**

### 1. Create Database Password Secret

**Using the password from your `.env` file:**

```bash
# Make sure .env is loaded
source .env

# Create secret using the DB_PASSWORD from .env
kubectl create secret generic db-credentials \
  --from-literal=password="$DB_PASSWORD"
```

**Note:** The password is stored in your local `.env` file which is gitignored, so it's never committed to version control.

### 2. Create Kubernetes Service Account for Backups

```bash
kubectl create serviceaccount backup-sa
```

### 3. Annotate SA with GCP Service Account

```bash
kubectl annotate serviceaccount backup-sa \
  iam.gke.io/gcp-service-account=db-backup-sa@$PROJECT_ID.iam.gserviceaccount.com
```

### 4. Deploy PostgreSQL

Create **`k8s/database.yaml`**

```yaml
# 1. Storage (The Hard Drive)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
---
# 2. Pod Disruption Budget (Prevents accidental deletion during maintenance)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postgres-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: postgres
---
# 3. Database Server
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: "postgres"
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      # Pin to Safe Node
      nodeSelector:
        role: safe-node

      containers:
      - name: postgres
        image: postgres:15-alpine

        # Resource limits prevent OOM
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"

        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password

        ports:
        - containerPort: 5432
          name: postgres

        # Health checks
        livenessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 30
          periodSeconds: 10

        readinessProbe:
          exec:
            command:
            - pg_isready
            - -U
            - postgres
          initialDelaySeconds: 5
          periodSeconds: 5

        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: postgres-storage
          subPath: postgres  # Prevents permission issues

      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
# 4. Internal Service
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgres
  clusterIP: None
```

**Execute:**
```bash
kubectl apply -f k8s/database.yaml
```

### 5. Wait for Database to be Ready

```bash
kubectl wait --for=condition=ready pod -l app=postgres --timeout=300s
```

### 6. Create Application Database

```bash
kubectl exec -it postgres-0 -- psql -U postgres -c "CREATE DATABASE myapp;"
```

**Verify:**
```bash
kubectl exec -it postgres-0 -- psql -U postgres -c "\l"
```

---

## **Phase 3: Networking (Cloudflare Tunnel)**

### 1. Create Tunnel in Cloudflare Dashboard

1. Go to **Zero Trust > Access > Tunnels**
2. Click **Create a tunnel**
3. Name it: `rails-cluster`
4. **Save the Token** (you'll need it in next step)
5. Configure **Public Hostname**:
   - **Subdomain**: `api`
   - **Domain**: `yoursite.com`
   - **Service**: `http://rails-service:3000`

### 2. Store Tunnel Token as Kubernetes Secret

**Add the token to your `.env` file first:**

```bash
# Edit your .env file and add this line:
echo 'CLOUDFLARE_TUNNEL_TOKEN="your-actual-token-here"' >> .env

# Reload the environment
source .env

# Create the Kubernetes secret
kubectl create secret generic cloudflare-tunnel \
  --from-literal=token="$CLOUDFLARE_TUNNEL_TOKEN"
```

### 3. Deploy Tunnel Agent

Create **`k8s/tunnel.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
spec:
  replicas: 2  # Redundancy
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --no-autoupdate
        - run

        env:
        - name: TUNNEL_TOKEN
          valueFrom:
            secretKeyRef:
              name: cloudflare-tunnel
              key: token

        # Resource limits
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"

        # Health check
        livenessProbe:
          httpGet:
            path: /ready
            port: 2000
          initialDelaySeconds: 30
          periodSeconds: 10
```

**Execute:**
```bash
kubectl apply -f k8s/tunnel.yaml
```

---

## **Phase 4: The Application (Rails)**

Create **`k8s/app.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rails-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: rails
  template:
    metadata:
      labels:
        app: rails
    spec:
      # ALLOW running on Spot Nodes
      tolerations:
      - key: "instance_type"
        operator: "Equal"
        value: "spot"
        effect: "NoSchedule"

      # PREFER running on Spot Nodes (Cost savings)
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: role
                operator: In
                values: ["worker-node"]

      containers:
      - name: rails
        image: ghcr.io/YOUR_GITHUB_USER/YOUR_REPO:latest

        ports:
        - containerPort: 3000
          name: http

        # Resource limits prevent OOM and ensure QoS
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"

        env:
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-credentials
              key: password
        - name: DATABASE_URL
          value: "postgres://postgres:$(POSTGRES_PASSWORD)@postgres-service:5432/myapp"
        - name: RAILS_ENV
          value: "production"

        # Health checks (create these endpoints in Rails)
        livenessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3

        readinessProbe:
          httpGet:
            path: /ready
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 2
---
apiVersion: v1
kind: Service
metadata:
  name: rails-service
spec:
  type: ClusterIP
  ports:
  - port: 3000
    targetPort: 3000
    protocol: TCP
    name: http
  selector:
    app: rails
```

**Execute:**
```bash
kubectl apply -f k8s/app.yaml
```

**Note:** You need to implement `/health` and `/ready` endpoints in your Rails app:

```ruby
# config/routes.rb
get '/health', to: 'health#index'
get '/ready', to: 'health#ready'

# app/controllers/health_controller.rb
class HealthController < ApplicationController
  def index
    render json: { status: 'ok' }, status: :ok
  end

  def ready
    # Check if database is accessible
    ActiveRecord::Base.connection.execute('SELECT 1')
    render json: { status: 'ready' }, status: :ok
  rescue => e
    render json: { status: 'not ready', error: e.message }, status: :service_unavailable
  end
end
```

---

## **Phase 5: Automated Deployment (GitHub Actions)**

### 1. Create GCP Service Account for CI/CD

```bash
# Create service account
gcloud iam service-accounts create github-actions \
  --display-name="GitHub Actions CI/CD"

# Grant necessary permissions
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:github-actions@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.developer"

# Create and download key
gcloud iam service-accounts keys create github-sa-key.json \
  --iam-account=github-actions@$PROJECT_ID.iam.gserviceaccount.com
```

### 2. Set GitHub Secrets

Go to your GitHub repo > **Settings** > **Secrets and variables** > **Actions** > **New repository secret**

Add these secrets:
- **GCP_PROJECT**: Your project ID
- **GCP_SA_KEY**: Contents of `github-sa-key.json` (paste the entire JSON)
- **DOCKER_REGISTRY**: `ghcr.io`
- **DOCKER_IMAGE_NAME**: `YOUR_GITHUB_USER/YOUR_REPO`

### 3. Create GitHub Actions Workflow

Create **`.github/workflows/deploy.yml`**

```yaml
name: Deploy to GKE

on:
  push:
    branches:
      - main

env:
  GCP_PROJECT: ${{ secrets.GCP_PROJECT }}
  GKE_CLUSTER: sb-cluster
  GKE_ZONE: asia-south1-a
  IMAGE: ghcr.io/${{ github.repository }}

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest

    permissions:
      contents: read
      packages: write

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to GitHub Container Registry
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}

    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        push: true
        tags: |
          ${{ env.IMAGE }}:${{ github.sha }}
          ${{ env.IMAGE }}:latest
        cache-from: type=gha
        cache-to: type=gha,mode=max

    - name: Authenticate to Google Cloud
      uses: google-github-actions/auth@v2
      with:
        credentials_json: ${{ secrets.GCP_SA_KEY }}

    - name: Set up Cloud SDK
      uses: google-github-actions/setup-gcloud@v2

    - name: Install gke-gcloud-auth-plugin
      run: |
        gcloud components install gke-gcloud-auth-plugin

    - name: Get GKE credentials
      run: |
        gcloud container clusters get-credentials ${{ env.GKE_CLUSTER }} \
          --zone=${{ env.GKE_ZONE }} \
          --project=${{ env.GCP_PROJECT }}

    - name: Deploy to GKE
      run: |
        kubectl set image deployment/rails-app \
          rails=${{ env.IMAGE }}:${{ github.sha }} \
          --record

        kubectl rollout status deployment/rails-app

    - name: Verify deployment
      run: |
        kubectl get services
        kubectl get pods -l app=rails
```

**Delete the local key for security:**
```bash
rm github-sa-key.json
```

---

## **Phase 6: Database Backups (The "Don't Get Fired" CronJob)**

Create **`k8s/backup.yaml`**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
spec:
  # Runs daily at 2:00 AM IST (20:30 UTC previous day)
  schedule: "30 20 * * *"
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 3

  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-sa  # Uses Workload Identity

          # Run on safe node (same as database)
          nodeSelector:
            role: safe-node

          restartPolicy: OnFailure

          containers:
          - name: backup
            image: google/cloud-sdk:alpine

            resources:
              requests:
                memory: "256Mi"
                cpu: "100m"
              limits:
                memory: "512Mi"
                cpu: "200m"

            command: ["/bin/sh", "-c"]
            args:
            - |
              set -e
              echo "Starting backup at $(date)"

              # Install PostgreSQL client
              apk add --no-cache postgresql-client

              # Set backup filename with date
              BACKUP_FILE="/tmp/backup-$(date +%Y-%m-%d-%H%M%S).sql"

              # Dump database
              echo "Dumping database..."
              PGPASSWORD=$DB_PASS pg_dump \
                -h postgres-service \
                -U postgres \
                -d myapp \
                --no-owner \
                --no-acl \
                > $BACKUP_FILE

              # Compress backup
              echo "Compressing backup..."
              gzip $BACKUP_FILE

              # Upload to GCS (Workload Identity handles auth)
              echo "Uploading to GCS..."
              gsutil cp ${BACKUP_FILE}.gz gs://${PROJECT_ID}-db-backups/backups/

              # Keep only last 30 days of backups
              echo "Cleaning old backups..."
              gsutil ls gs://${PROJECT_ID}-db-backups/backups/ | \
                head -n -30 | \
                xargs -r gsutil rm

              echo "Backup completed successfully at $(date)"

            env:
            - name: DB_PASS
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
            - name: PROJECT_ID
              value: "YOUR_PROJECT_ID"  # Replace with your actual project ID from .env
```

**Execute:**
```bash
kubectl apply -f k8s/backup.yaml
```

**Test backup immediately (don't wait for cron):**
```bash
kubectl create job --from=cronjob/db-backup manual-backup-test
kubectl logs -f job/manual-backup-test
```

---

## **Phase 7: Monitoring & Cost Control**

### 1. Set Up Budget Alerts

```bash
# Set up a budget alert (requires billing account ID)
gcloud billing budgets create \
  --billing-account=YOUR_BILLING_ACCOUNT_ID \
  --display-name="GKE Monthly Budget" \
  --budget-amount=30USD \
  --threshold-rule=percent=50 \
  --threshold-rule=percent=75 \
  --threshold-rule=percent=90 \
  --threshold-rule=percent=100
```

### 2. View Costs in Console

Go to: https://console.cloud.google.com/billing/reports

Filter by:
- **Project**: Your project
- **Services**: Kubernetes Engine, Compute Engine
- **Labels**: Match your resource labels

### 3. Monitor Cluster Health

```bash
# View cluster status
kubectl get nodes
kubectl top nodes
kubectl top pods

# Check logs
kubectl logs -l app=rails --tail=100
kubectl logs -l app=postgres --tail=100

# View events
kubectl get events --sort-by='.lastTimestamp'
```

### 4. Set Up Uptime Monitoring (Optional - Free tier available)

Go to: https://console.cloud.google.com/monitoring/uptime

Create uptime check for your Cloudflare URL.

---

## **Phase 8: Disaster Recovery Procedures**

### How to Restore from Backup

**If your database gets corrupted or deleted:**

```bash
# 1. List available backups
gsutil ls gs://$PROJECT_ID-db-backups/backups/

# 2. Download the backup you want
gsutil cp gs://$PROJECT_ID-db-backups/backups/backup-YYYY-MM-DD-HHMMSS.sql.gz /tmp/

# 3. Decompress
gunzip /tmp/backup-YYYY-MM-DD-HHMMSS.sql.gz

# 4. Copy to a pod (create a temporary restore pod if needed)
kubectl cp /tmp/backup-YYYY-MM-DD-HHMMSS.sql postgres-0:/tmp/restore.sql

# 5. Restore the database
kubectl exec -it postgres-0 -- bash -c "PGPASSWORD=\$POSTGRES_PASSWORD psql -U postgres -d myapp < /tmp/restore.sql"

# 6. Verify
kubectl exec -it postgres-0 -- psql -U postgres -d myapp -c "SELECT COUNT(*) FROM your_table;"
```

### How to Scale Up for Traffic Spike

```bash
# Increase spot node pool
kubectl scale deployment/rails-app --replicas=5

# Or update via terraform
# Edit variables.tf: spot_pool_max_nodes = 10
# Then: terraform apply
```

### How to Update Application

```bash
# Rolling update (zero downtime)
kubectl set image deployment/rails-app rails=ghcr.io/user/repo:new-tag

# Watch rollout
kubectl rollout status deployment/rails-app

# Rollback if needed
kubectl rollout undo deployment/rails-app
```

---

## **Final Checklist**

Before going to production, verify:

- [ ] All GCP APIs enabled
- [ ] Initial `terraform apply` completed (creates buckets with local state)
- [ ] State migrated to GCS (`terraform init -migrate-state`)
- [ ] Buckets created (state and backup)
- [ ] kubectl connected to cluster
- [ ] Database secret created
- [ ] Database deployed and accessible
- [ ] Application database `myapp` created
- [ ] Cloudflare tunnel configured
- [ ] Tunnel token stored as secret
- [ ] Tunnel agent deployed
- [ ] Rails app deployed
- [ ] Health endpoints working (`/health`, `/ready`)
- [ ] GitHub Actions secrets configured
- [ ] Backup cronjob deployed
- [ ] Test backup completed successfully
- [ ] Budget alerts configured
- [ ] Monitoring dashboards bookmarked
- [ ] Disaster recovery procedures documented

---

## **Expected Monthly Cost Breakdown**

| Resource | Cost |
|----------|------|
| GKE Control Plane (Zonal) | $0 |
| Safe Node (e2-small) | ~$13 |
| Spot Node (e2-medium, active) | ~$7 |
| Persistent Disk (10GB) | ~$0.40 |
| Backup Storage (incremental) | ~$0.50 |
| Egress Traffic (minimal) | ~$1 |
| **Total** | **~$20-22/month** |

---

## **Support & Troubleshooting**

### Common Issues

**Pods stuck in Pending:**
```bash
kubectl describe pod <pod-name>
# Look for "Events" section for errors
```

**Database connection refused:**
```bash
# Check if postgres is running
kubectl get pods -l app=postgres

# Check service
kubectl get svc postgres-service

# Test connection from another pod
kubectl run -it --rm debug --image=postgres:15-alpine --restart=Never -- psql -h postgres-service -U postgres
```

**Cloudflare tunnel not working:**
```bash
# Check tunnel logs
kubectl logs -l app=cloudflared

# Verify secret exists
kubectl get secret cloudflare-tunnel
```

**Out of memory errors:**
```bash
# Check resource usage
kubectl top pods

# Increase limits in deployment YAML
```

---

**You now have a production-ready, cost-optimized GKE cluster with full monitoring, backups, and disaster recovery!** 🚀
