# Shuffle Deployment Guide

This guide covers deploying Shuffle using Terraform on Google Cloud Platform (GCP).

## Prerequisites

- Google Cloud Project with billing enabled
- Terraform >= 1.0 installed
- `gcloud` CLI installed and authenticated
- Appropriate IAM permissions (Compute Admin, Network Admin)

## Terraform Deployment

### Quick Start

1. **Clone the Repository:**
   ```bash
   git clone https://github.com/Shuffle/Shuffle.git
   cd Shuffle/terraform
   ```

2. **Initialize Terraform:**
   ```bash
   terraform init
   ```

3. **Configure Variables:**
   Create a `terraform.tfvars` file:
   ```hcl
   project_id              = "your-gcp-project-id"
   goog_cm_deployment_name = "shuffle-deployment"
   region                  = "us-central1"
   node_count              = 3  # 1-10 nodes supported
   machine_type            = "e2-standard-4"
   ```

4. **Deploy Infrastructure:**
   ```bash
   # Review the deployment plan
   terraform plan

   # Apply the configuration
   terraform apply
   ```

5. **Access Shuffle:**
   After deployment completes (~10-15 minutes):
   ```bash
   # Get the frontend URL
   terraform output frontend_url
   ```

### Configuration Options

#### Required Variables
| Variable | Description | Example |
|----------|-------------|---------|
| `project_id` | Your GCP project ID | `"my-project-123"` |
| `goog_cm_deployment_name` | Unique deployment name | `"shuffle-prod"` |

#### Optional Variables
| Variable | Description | Default |
|----------|-------------|---------|
| `region` | GCP region for deployment | `"australia-southeast1"` |
| `node_count` | Number of nodes (1-10) | `1` |
| `machine_type` | GCP machine type | `"e2-standard-2"` |
| `boot_disk_size` | Boot disk size in GB | `120` |
| `boot_disk_type` | Disk type (pd-standard/pd-ssd/pd-balanced) | `"pd-standard"` |
| `subnet_cidr` | Internal network CIDR | `"10.224.0.0/16"` |
| `external_access_cidrs` | Allowed IPs for frontend access | `"0.0.0.0/0"` |
| `enable_ssh` | Enable SSH access | `true` |
| `ssh_source_ranges` | Allowed IPs for SSH | `"0.0.0.0/0"` |
| `environment` | Environment label | `"production"` |

### Deployment Examples

#### Single Node (Development)
```hcl
# terraform.tfvars
project_id              = "your-project"
goog_cm_deployment_name = "shuffle-dev"
node_count              = 1
machine_type            = "e2-standard-2"
environment             = "dev"
```

#### Multi-Node High Availability (Production)
```hcl
# terraform.tfvars
project_id              = "your-project"
goog_cm_deployment_name = "shuffle-prod"
node_count              = 3
machine_type            = "e2-standard-4"
boot_disk_type          = "pd-ssd"
external_access_cidrs   = "203.0.113.0/24"  # Restrict access
environment             = "production"
```

### What Gets Deployed

The Terraform configuration automatically provisions:

#### Infrastructure
- **VPC Network**: Isolated network for Shuffle
- **Subnet**: Private subnet with configurable CIDR
- **Firewall Rules**: 
  - Internal: Docker Swarm, NFS, OpenSearch, Backend services
  - External: Port 3001 (Frontend) only
- **Compute Instances**: Configured number of nodes with Docker Swarm

#### Shuffle Services (Auto-deployed via startup script)
- **Frontend**: Web UI (port 3001)
- **Backend**: API server
- **Orborus**: Workflow orchestrator
- **Workers**: App execution workers
- **OpenSearch**: Data storage and search
- **Memcached**: Caching layer
- **NFS**: Shared storage across nodes

## Managing the Deployment

### Viewing Resources
```bash
# List all deployed resources
terraform state list

# Show specific resource details
terraform state show google_compute_instance.swarm_manager[0]

# Get outputs
terraform output
```

### Scaling
To change the number of nodes:
```bash
# Update terraform.tfvars
node_count = 5  # New desired count

# Apply changes
terraform apply
```

### SSH Access
```bash
# Get instance names
gcloud compute instances list --filter="labels.deployment=shuffle-deployment"

# SSH to a node
gcloud compute ssh shuffle-deployment-manager-1 --zone=us-central1-a
```

### Monitoring Services
Once connected to a node:
```bash
# Check Docker Swarm status
docker node ls

# View running services
docker service ls

# Check service logs
docker service logs shuffle_frontend
```

## Deletion/Cleanup

### Complete Cleanup
To remove all Shuffle infrastructure:

```bash
# Destroy all resources
terraform destroy

# Confirm by typing 'yes' when prompted
```

This will delete:
- All compute instances
- Network and firewall rules
- Instance groups
- All associated resources

### Partial Cleanup
To remove specific resources:
```bash
# Target specific resources for destruction
terraform destroy -target=google_compute_instance.swarm_manager

# Or remove from state and manage manually
terraform state rm google_compute_instance.swarm_manager
```

### Post-Deletion Cleanup
After Terraform deletion, verify cleanup:
```bash
# Check for remaining resources
gcloud compute instances list --filter="labels.deployment=shuffle-deployment"
gcloud compute firewall-rules list --filter="name:shuffle-*"
gcloud compute networks list --filter="name:shuffle-*"

# Manually delete any remaining resources if needed
gcloud compute instances delete INSTANCE_NAME --zone=ZONE
```

## Troubleshooting

### Deployment Issues
If deployment fails:
```bash
# Check Terraform state
terraform state list

# Review detailed logs
terraform apply -debug

# Check instance startup logs
gcloud compute instances get-serial-port-output shuffle-deployment-manager-1
```

### Service Issues
```bash
# SSH to manager node
gcloud compute ssh shuffle-deployment-manager-1

# Check Docker Swarm
docker node ls
docker service ls
docker service ps shuffle_frontend

# View logs
docker service logs shuffle_frontend --follow
```

### Network Issues
Ensure firewall rules are correctly applied:
```bash
gcloud compute firewall-rules list --filter="network:shuffle-*"
```

## Important Notes

- **Data Persistence**: Data is stored on NFS shared between nodes. Back up important data before deletion.
- **Costs**: Running instances incur charges. Use `terraform destroy` when not needed.
- **Security**: Default configuration exposes port 3001. Restrict `external_access_cidrs` in production.
- **Scaling Limits**: Maximum 10 nodes supported by default configuration.

## Support

For issues or questions:
- Check logs: `gcloud compute instances get-serial-port-output INSTANCE_NAME`
- Review Terraform state: `terraform state show`
- Consult Shuffle documentation: https://shuffler.io/docs