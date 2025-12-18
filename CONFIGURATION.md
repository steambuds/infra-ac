# Configuration Guide

This project uses local configuration files to manage secrets and settings without committing them to version control.

## Quick Start

1. **Copy the environment template:**
   ```bash
   cp .env.example .env
   ```

2. **Edit `.env` with your actual values:**
   ```bash
   nano .env  # or use your preferred editor
   ```

3. **Load the configuration:**
   ```bash
   source setup.sh
   # OR manually:
   source .env
   ```

4. **For Terraform, copy the tfvars template:**
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   nano terraform.tfvars
   ```

## Configuration Files

### `.env` - Shell Environment Variables
Used for bash scripts and manual commands. Contains:
- GCP project details (PROJECT_ID, REGION, ZONE)
- Database passwords
- API tokens (Cloudflare, etc.)
- GitHub configuration

**Location:** Project root
**Git Status:** Ignored (never committed)
**Template:** `.env.example`

### `terraform.tfvars` - Terraform Variables
Used by Terraform for infrastructure provisioning. Contains:
- All infrastructure settings
- Node pool configurations
- Resource labels

**Location:** Project root
**Git Status:** Ignored (never committed)
**Template:** `terraform.tfvars.example`

### `setup.sh` - Helper Script
Loads `.env` and validates configuration.

**Usage:**
```bash
source setup.sh
```

## Security Best Practices

✅ **DO:**
- Keep `.env` and `terraform.tfvars` in `.gitignore`
- Use the template files (`.example`) as references
- Store secrets in `.env` for local use
- Use GCP Secret Manager for production secrets
- Rotate credentials regularly

❌ **DON'T:**
- Commit `.env` or `terraform.tfvars` to git
- Share your `.env` file
- Hardcode secrets in YAML or TF files
- Use the same credentials across environments

## Environment Variables Reference

| Variable | Description | Example |
|----------|-------------|---------|
| `PROJECT_ID` | GCP Project ID | `my-project-123` |
| `REGION` | GCP Region | `asia-south1` |
| `ZONE` | GCP Zone | `asia-south1-a` |
| `CLUSTER_NAME` | GKE Cluster name | `sb-cluster` |
| `DB_PASSWORD` | PostgreSQL password | `SecurePass123!` |
| `CLOUDFLARE_TUNNEL_TOKEN` | CF Tunnel token | `eyJh...` |
| `GITHUB_USER` | GitHub username | `yourusername` |
| `GITHUB_REPO` | Repository name | `yourrepo` |

## Terraform Variables Reference

See `terraform.tfvars.example` for all available options.

Key variables:
- `project_id` - GCP Project ID
- `safe_pool_machine_type` - Machine type for database nodes
- `spot_pool_machine_type` - Machine type for app nodes
- `labels` - Resource labels for cost tracking

## Configuration Precedence (What Overrides What?)

Understanding which configuration source "wins" when multiple sources define the same value.

### Terraform Precedence (Highest to Lowest Priority)

When running `terraform apply`:

```
1. Command-line flags             (HIGHEST - overrides everything)
   terraform apply -var="project_id=xyz"

2. *.auto.tfvars files            (Alphabetically loaded)

3. terraform.tfvars file          ← YOU USE THIS (RECOMMENDED)

4. TF_VAR_* environment variables (From .env if you export them)
   export TF_VAR_project_id=$PROJECT_ID

5. variables.tf defaults          (LOWEST - fallback only)
```

**Example:**
```hcl
# variables.tf has: default = "default-project"
# terraform.tfvars has: project_id = "my-project"
# You run: terraform apply

Result: Uses "my-project" (terraform.tfvars overrides default)
```

### Bash/Shell Precedence (Highest to Lowest Priority)

When running shell commands (gcloud, kubectl, etc.):

```
1. Explicitly exported variables  (HIGHEST)
   export PROJECT_ID="override"

2. Sourced .env file             ← YOU USE THIS (RECOMMENDED)
   source .env

3. System environment variables   (LOWEST - from ~/.bashrc, etc.)
```

**Example:**
```bash
# System has: PROJECT_ID="system-value" (in ~/.bashrc)
# .env has: PROJECT_ID="env-value"
# You run: source .env

Result: Uses "env-value" (sourced .env overrides system)
```

### Quick Comparison Table

| Priority | Terraform | Bash Commands |
|----------|-----------|---------------|
| 1 (Highest) | `-var` flag | `export VAR=value` |
| 2 | `*.auto.tfvars` | `source .env` |
| 3 | `terraform.tfvars` | System env vars |
| 4 | `TF_VAR_*` env vars | - |
| 5 (Lowest) | `variables.tf` defaults | Variable not set |

### Important Notes

1. **`.env` doesn't automatically work with Terraform!**
   - You must create `terraform.tfvars` with the same values
   - OR export as `TF_VAR_*` variables

2. **Keep values in sync:**
   ```bash
   # Both should have same PROJECT_ID
   .env:              PROJECT_ID="my-project"
   terraform.tfvars:  project_id = "my-project"
   ```

3. **Temporary overrides:**
   ```bash
   # Override just for one command (doesn't change files)
   terraform apply -var="project_id=temp"
   PROJECT_ID="temp" gcloud config set project $PROJECT_ID
   ```

## Using Variables in Different Contexts

### In Bash Scripts
```bash
source .env
echo "Project: $PROJECT_ID"
gcloud config set project $PROJECT_ID
```

### In Terraform
```bash
# Option 1: Use terraform.tfvars (RECOMMENDED)
terraform apply  # Automatically finds terraform.tfvars

# Option 2: Use environment variables
export TF_VAR_project_id=$PROJECT_ID
terraform apply

# Option 3: Pass on command line (temporary override)
terraform apply -var="project_id=$PROJECT_ID"
```

### In Kubernetes
```bash
# Load .env first
source .env

# Use variables in kubectl commands
kubectl create secret generic db-credentials \
  --from-literal=password="$DB_PASSWORD"
```

## Troubleshooting

**Variables not loaded?**
```bash
# Make sure to source, not execute
source .env  # ✅ Correct
./env        # ❌ Wrong
```

**Terraform not finding variables?**
```bash
# Verify terraform.tfvars exists
ls -la terraform.tfvars

# Check variable values
terraform console
> var.project_id
```

**Permission denied on setup.sh?**
```bash
chmod +x setup.sh
```

## Multi-Environment Setup

For multiple environments (dev, staging, prod):

```bash
# Create environment-specific files
.env.dev
.env.staging
.env.prod

# Load the one you need
source .env.dev
```

Or use Terraform workspaces:
```bash
terraform workspace new dev
terraform workspace new prod
```

## Related Files

- `.gitignore` - Ensures sensitive files aren't committed
- `variables.tf` - Terraform variable definitions with defaults
- `plan.md` - Complete deployment plan
- `README.md` - Project overview
