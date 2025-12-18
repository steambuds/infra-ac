# Infra as Code (IaC)
* completed the Phase one
* enable [Google Compute Engine API](https://console.developers.google.com/apis/library/compute.googleapis.com)
* authenticate using `gcloud auth application-default login`
* run `terraform init` it downloads the providers configuration in .terraform directory.
* run `terraform fmt` to format the terraform files.
* run `terraform validate` will validate the configuration.









q





This is the **Execution Master Plan** for your "Extreme Budget" Hybrid Architecture.

**The Goal:** A scalable Rails app with Postgres on Google Cloud + Cloudflare for **~$20-25/month**.

**The Catch:** To keep costs this low, we are using **Public Nodes with Ephemeral IPs** (Free) and relying on **Cloudflare Tunnel** to route traffic. We avoid "Private Clusters" because they require a Cloud NAT Gateway ($32/mo).

---

### Phase 1: The Setup (Local Environment)

*Before writing code, ensure you have these installed:*

1. **Google Cloud SDK** (`gcloud`) & **Terraform**.
2. **Kubectl** (Kubernetes CLI).
3. **Cloudflared** (CLI tool for testing).
4. **Accounts:**
* Google Cloud (Billing enabled).
* Cloudflare (Free account).
* GitHub (Repo created).



---

### Phase 2: Infrastructure as Code (Terraform)

We create the "Zonal" cluster to get the Control Plane for free.

**Action:** Create a folder `terraform/` and create `main.tf`.

```hcl
# main.tf
provider "google" {
  project = "YOUR_PROJECT_ID"
  region  = "us-central1"
}

# 1. The Network (VPC)
resource "google_compute_network" "vpc" {
  name                    = "rails-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "rails-subnet"
  region        = "us-central1"
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.0.0.0/24"
}

# 2. The GKE Cluster (Zonal = Free Control Plane)
resource "google_container_cluster" "primary" {
  name     = "rails-cluster"
  location = "us-central1-a" # Zonal
  
  remove_default_node_pool = true
  initial_node_count       = 1
  network                  = google_compute_network.vpc.name
  subnetwork               = google_compute_subnetwork.subnet.name
}

# 3. The "Safe" Node Pool (Postgres + System)
resource "google_container_node_pool" "safe_pool" {
  name       = "safe-pool"
  location   = "us-central1-a"
  cluster    = google_container_cluster.primary.name
  node_count = 1

  node_config {
    machine_type = "e2-small"  # 2 vCPU, 2GB RAM (~$13/mo)
    disk_size_gb = 30
    spot         = false       # Keep this alive!
    labels       = { role = "safe-node" }
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# 4. The "Spot" Node Pool (Rails App)
resource "google_container_node_pool" "spot_pool" {
  name       = "spot-pool"
  location   = "us-central1-a"
  cluster    = google_container_cluster.primary.name
  
  autoscaling {
    min_node_count = 0
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-medium" # 2 vCPU, 4GB RAM (~$7/mo via Spot)
    spot         = true        # Preemptible
    labels       = { role = "worker-node" }
    taint {
      key    = "instance_type"
      value  = "spot"
      effect = "NO_SCHEDULE"
    }
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

```

**Run:** `terraform init` and `terraform apply`.

---

### Phase 3: The Database (Postgres on K8s)

We pin the database to the "Safe Node" so it doesn't get deleted.

**Action:** Create `k8s/database.yaml`.

```yaml
# k8s/database.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard # Cheapest disk
---
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
      nodeSelector:
        role: safe-node # PIN TO SAFE NODE
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_PASSWORD
          value: "secure_password_here" # Use Secrets!
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: postgres-storage
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-service
spec:
  ports:
  - port: 5432
  selector:
    app: postgres
  clusterIP: None # Internal only

```

**Run:** `kubectl apply -f k8s/database.yaml`

---

### Phase 4: Cloudflare Setup (Tunnel + R2)

This replaces the Load Balancer and S3.

**Step A: Cloudflare Tunnel**

1. Go to **Zero Trust Dashboard** > **Access** > **Tunnels**.
2. Create a tunnel named `rails-production`.
3. Copy the **Tunnel Token**.
4. In the "Public Hostnames" tab, add:
* **Public:** `api.yoursite.com`
* **Service:** `http://rails-service:3000` (Internal K8s DNS).



**Step B: Cloudflare R2 (File Storage)**

1. Go to **R2** in Dashboard.
2. Create bucket `rails-assets`.
3. Generate **Access Keys** (Key ID & Secret).
4. Update your Rails `config/storage.yml` to use S3-compatible mode with these keys.

---

### Phase 5: The Application & Tunnel Deployment

We deploy your Rails app AND the Cloudflare agent (`cloudflared`) to expose it.

**Action:** Create `k8s/app.yaml`.

```yaml
# k8s/app.yaml
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
      # Use Spot Nodes if available
      tolerations:
      - key: "instance_type"
        operator: "Equal"
        value: "spot"
        effect: "NO_SCHEDULE"
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
      # 1. Your Rails App
      - name: rails
        image: ghcr.io/YOUR_USER/YOUR_REPO:latest
        ports:
        - containerPort: 3000
        env:
        - name: DATABASE_URL
          value: "postgres://postgres:password@postgres-service:5432/myapp"

      # 2. Cloudflare Tunnel Sidecar (The Connector)
      - name: cloudflared
        image: cloudflare/cloudflared:latest
        args:
        - tunnel
        - --no-autoupdate
        - run
        env:
        - name: TUNNEL_TOKEN
          value: "YOUR_CF_TUNNEL_TOKEN"
---
apiVersion: v1
kind: Service
metadata:
  name: rails-service
spec:
  ports:
  - port: 3000
  selector:
    app: rails

```

**Run:** `kubectl apply -f k8s/app.yaml`

---

### Phase 6: CI/CD (GitHub Actions)

Automate the deployment so you never have to touch `kubectl` manually.

**Action:** Create `.github/workflows/deploy.yml`.

1. **Secrets:** Go to GitHub Repo > Settings > Secrets and add:
* `GCP_SA_KEY` (JSON Key)
* `GCP_PROJECT`
* `CF_TUNNEL_TOKEN` (Optional, if you want to rotate it)


2. **Workflow Code:** Use the workflow I provided in the previous response. It builds the Docker image, pushes to GHCR, and runs `kubectl set image`.

---

### Phase 7: The "Disaster Proofing" (Don't Skip)

Since we are "Self-Hosting" the database, you are responsible for backups.

**Action:** Create a Kubernetes CronJob that dumps the DB to Google Cloud Storage (GCS) or Cloudflare R2 every night.

```yaml
# k8s/backup-cron.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-backup
spec:
  schedule: "0 2 * * *" # Every day at 2am
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:15-alpine
            command: ["/bin/sh", "-c"]
            args:
            - PGPASSWORD=password pg_dump -h postgres-service -U postgres myapp > /tmp/backup.sql &&
              # Add logic here to upload /tmp/backup.sql to R2/GCS
              echo "Backup Done"
          restartPolicy: OnFailure

```

### Summary of Costs

* **GKE Control Plane:** $0
* **Safe Node (e2-small):** ~$13
* **Spot Node (e2-medium):** ~$7 (when active)
* **Load Balancer:** $0 (Replaced by Tunnel)
* **Static IP:** $0 (Not needed with Tunnel)
* **Traffic:** $0 (Cloudflare absorbs mostly)
* **Total:** **~$20 - $25 / month**

**Which phase would you like to start with? I can help you write the specific `Dockerfile` optimization or the Terraform scripts first.**

