# Shuffle Terraform Deployment for Google Cloud Marketplace

This Terraform module deploys Shuffle security orchestration platform on Google Cloud Platform as a scalable Docker Swarm cluster.

## Features

- **Scalable Architecture**: Deploy 1 to 10 nodes automatically configured as Docker Swarm
- **Automatic Role Assignment**: First 3 nodes become managers, additional nodes are workers
- **NFS Configuration**: Automatic NFS setup for shared storage across nodes
- **Load Balancing**: Built-in Nginx load balancer across all nodes
- **OpenSearch Cluster**: Distributed search with automatic replication
- **Security**: Configurable firewall rules and access controls

## Quick Start

### Prerequisites

1. Google Cloud Project with billing enabled
2. Terraform >= 1.0
3. Required APIs enabled:
   - Compute Engine API
   - Cloud Logging API (optional)
   - Cloud Monitoring API (optional)

### Basic Deployment

```hcl
module "shuffle" {
  source = "path/to/terraform"

  project_id              = "your-project-id"
  goog_cm_deployment_name = "shuffle-deployment"
  node_count              = 3  # Deploy 3 VMs
  machine_type            = "e2-standard-2"
  boot_disk_size          = 120
}
```

### Deployment Steps

1. Initialize Terraform:
   ```bash
   terraform init
   ```

2. Review the deployment plan:
   ```bash
   terraform plan -var project_id=YOUR_PROJECT_ID
   ```

3. Deploy:
   ```bash
   terraform apply -var project_id=YOUR_PROJECT_ID
   ```

4. Get admin password:
   ```bash
   terraform output -raw admin_password
   ```

## Configuration Options

### Node Scaling

- `node_count`: Number of VMs (1-10)
  - 1-3 nodes: All become managers
  - 4+ nodes: First 3 are managers, rest are workers

### Machine Configuration

- `machine_type`: GCP machine type (default: e2-standard-2)
- `boot_disk_size`: Disk size in GB (50-1000, default: 120)
- `boot_disk_type`: Disk type (pd-standard, pd-ssd, pd-balanced)

### Network & Security

- `external_access_cidrs`: CIDR ranges for UI access (default: 0.0.0.0/0)
- `enable_https`: Enable HTTPS on port 3443 (default: true)
- `enable_ssh`: Enable SSH access (default: true)
- `ssh_source_ranges`: CIDR ranges for SSH (default: 0.0.0.0/0)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Load Balancer (Nginx)                  │
│                    Ports: 3001, 3443                     │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────┴────────────────────────────────────┐
│                    Docker Swarm Cluster                  │
├──────────────────────────────────────────────────────────┤
│  Manager Nodes (1-3)        │   Worker Nodes (0-7)      │
│  - Swarm Management          │   - Task Execution        │
│  - NFS Server (Primary)      │   - NFS Client           │
│  - Service Orchestration     │   - Container Runtime    │
└──────────────────────────────────────────────────────────┘
                     │
┌──────────────────────────────────────────────────────────┐
│                        Services                          │
├───────────────┬──────────────┬──────────────┬───────────┤
│   Frontend    │   Backend    │  OpenSearch  │  Orborus  │
│   (UI/UX)     │   (API)      │  (Database)  │  (Worker) │
└───────────────┴──────────────┴──────────────┴───────────┘
```

## Post-Deployment

### Access URLs

After deployment, access Shuffle at:
- **Frontend**: `http://<PRIMARY_MANAGER_IP>:3001`
- **HTTPS**: `https://<PRIMARY_MANAGER_IP>:3443`
- **OpenSearch**: `http://<PRIMARY_MANAGER_IP>:9200`

### Default Credentials

- **Username**: `admin@shuffle.local` (configurable)
- **Password**: Auto-generated (retrieve with `terraform output -raw admin_password`)

### Management Commands

SSH to primary manager:
```bash
gcloud compute ssh <MANAGER_NAME> --zone=<ZONE>
```

View services:
```bash
docker stack services shuffle
```

View logs:
```bash
docker service logs shuffle_backend
```

## Customization

### Environment Variables

Customize Shuffle behavior by modifying the configuration downloads in `scripts/startup-simple.sh`.

## Troubleshooting

### Common Issues

1. **Nodes not joining swarm**: Check firewall rules allow ports 2377, 7946, 4789
2. **NFS mount failures**: Ensure primary manager is fully initialized
3. **Service deployment issues**: Verify Docker Swarm status with `docker node ls`

### Debug Commands

Check node status:
```bash
docker node ls
```

Check service status:
```bash
docker stack services shuffle
```

Check NFS mounts:
```bash
showmount -e <PRIMARY_MANAGER_IP>
```

## Security Considerations

1. **Network Security**: Configure `external_access_cidrs` to limit access
2. **SSH Access**: Restrict `ssh_source_ranges` to known IPs
3. **Admin Password**: Change default admin password after first login
4. **Firewall Rules**: Review and adjust based on security requirements

## Support

For issues and documentation:
- [Shuffle Documentation](https://shuffler.io/docs)
- [GitHub Issues](https://github.com/shuffle/shuffle)

## License

This deployment configuration is provided as-is for use with Shuffle open-source platform.