# Terraform Testing Guide

## Industry Standard Testing Approach

### 1. Testing Pyramid for Terraform

```
        /\
       /  \  E2E Tests (Full deployment on GCP)
      /    \
     /------\ Integration Tests (Module testing)
    /        \
   /----------\ Unit Tests (Validation, formatting)
  /            \
 /--------------\ Static Analysis (lint, security scan)
```

### 2. Testing Stages

#### Stage 1: Local Validation (No GCP Resources)
```bash
# Format check
terraform fmt -check -recursive

# Validate syntax
terraform validate

# Security scanning with tfsec
tfsec .

# Cost estimation
infracost breakdown --path .
```

#### Stage 2: Plan Testing (No GCP Resources)
```bash
# Generate plan without applying
terraform plan -var-file=test/terraform.tfvars -out=test.tfplan

# Convert plan to JSON for analysis
terraform show -json test.tfplan > test.tfplan.json

# Analyze with tools like OPA (Open Policy Agent)
opa eval -d policies/ -i test.tfplan.json "data.terraform.analysis.deny[msg]"
```

#### Stage 3: Integration Testing (GCP Resources)
```bash
# Deploy test environment
cd terraform/test
./test-deployment.sh apply

# Run tests against deployed infrastructure
./run-integration-tests.sh

# Cleanup
terraform destroy -auto-approve
```

#### Stage 4: E2E Testing (Full Deployment)
- Deploy complete stack
- Run smoke tests
- Verify all services are running
- Test failover scenarios
- Clean up resources

## Testing on Your GCP Project

### Prerequisites
```bash
# Authenticate with GCP
gcloud auth login
gcloud config set project shuffle-australia-southeast1

# Enable required APIs
gcloud services enable compute.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com
```

### Quick Test Deployment

#### Single Node Test
```bash
cd terraform
terraform init
terraform apply \
  -var="project_id=shuffle-australia-southeast1" \
  -var="goog_cm_deployment_name=shuffle-test-single" \
  -var="region=australia-southeast1" \
  -var="node_count=1"
```

#### Multi-Node Cluster Test
```bash
cd terraform
terraform apply \
  -var="project_id=shuffle-australia-southeast1" \
  -var="goog_cm_deployment_name=shuffle-test-cluster" \
  -var="region=australia-southeast1" \
  -var="node_count=3"
```

### Automated Test Script
```bash
# Run the provided test script
cd terraform/test
./test-deployment.sh       # Plan only
./test-deployment.sh apply  # Plan and apply
```

## Test Scenarios

### 1. Single Node Deployment
- Verify all services start on single node
- Check NFS is configured correctly
- Validate frontend is accessible on port 3001
- Ensure no other ports are exposed externally

### 2. Three Node Cluster
- Verify 3 manager nodes are created
- Check Docker Swarm cluster forms correctly
- Validate NFS mounting across nodes
- Test service distribution across nodes

### 3. Scale Up Test (3 → 5 nodes)
```bash
terraform apply -var="node_count=5" -auto-approve
```
- Verify new nodes join as workers
- Check service scaling
- Validate load distribution

### 4. Network Security Test
```bash
# Test external access (should work)
curl http://<EXTERNAL_IP>:3001

# Test internal services (should fail from external)
curl http://<EXTERNAL_IP>:9200  # Should timeout
curl http://<EXTERNAL_IP>:5001  # Should timeout

# Test from within VPC (SSH to a node first)
gcloud compute ssh shuffle-test-manager-1 --zone=australia-southeast1-a
curl http://localhost:9200  # Should work internally
```

### 5. Failover Test
```bash
# Stop primary manager
gcloud compute instances stop shuffle-test-manager-1 --zone=australia-southeast1-a

# Verify cluster continues operating
# Check services migrate to other nodes
```

## CI/CD Pipeline Testing

### GitHub Actions Example
```yaml
name: Terraform Test

on:
  pull_request:
    paths:
      - 'terraform/**'

jobs:
  terraform-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        
      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        
      - name: Terraform Init
        run: terraform init
        
      - name: Terraform Validate
        run: terraform validate
        
      - name: Terraform Plan
        run: terraform plan -var="project_id=${{ secrets.GCP_PROJECT }}"
        env:
          GOOGLE_CREDENTIALS: ${{ secrets.GCP_SA_KEY }}
```

## Cost Management

### Estimate Costs Before Deployment
```bash
# Using infracost
infracost breakdown --path . \
  --terraform-var="node_count=3" \
  --terraform-var="machine_type=e2-standard-2"
```

### Resource Cleanup
```bash
# List all resources
terraform state list

# Destroy specific deployment
terraform destroy \
  -var="project_id=shuffle-australia-southeast1" \
  -var="goog_cm_deployment_name=shuffle-test" \
  -auto-approve

# Clean up orphaned resources
gcloud compute instances list --filter="name:shuffle-test-*"
gcloud compute firewall-rules list --filter="name:shuffle-test-*"
```

## Monitoring Test Deployments

### View Instances
```bash
gcloud compute instances list \
  --filter="name:shuffle-*" \
  --project=shuffle-australia-southeast1
```

### Check Logs
```bash
# View startup script logs
gcloud compute instances get-serial-port-output \
  shuffle-test-manager-1 \
  --zone=australia-southeast1-a
```

### SSH Access
```bash
gcloud compute ssh shuffle-test-manager-1 \
  --zone=australia-southeast1-a \
  --project=shuffle-australia-southeast1

# Once connected, check Docker Swarm
docker node ls
docker stack services shuffle
docker service logs shuffle_backend
```

## Test Checklist

- [ ] Terraform validates successfully
- [ ] Single node deploys and initializes
- [ ] Services are accessible on port 3001
- [ ] No other ports exposed externally
- [ ] Multi-node cluster forms correctly
- [ ] NFS mounts work across nodes
- [ ] Services distribute across nodes
- [ ] Admin password is generated
- [ ] Can SSH to nodes
- [ ] Docker Swarm is healthy
- [ ] All containers are running
- [ ] Frontend loads in browser
- [ ] Can log in with admin credentials
- [ ] Resources clean up properly

## Troubleshooting

### Common Issues

1. **API not enabled**
   ```bash
   gcloud services enable compute.googleapis.com
   ```

2. **Insufficient quota**
   - Check quotas: `gcloud compute project-info describe`
   - Request increase if needed

3. **Network issues**
   - Verify firewall rules: `gcloud compute firewall-rules list`
   - Check instance IPs: `gcloud compute instances list`

4. **Startup script failures**
   - Check serial output for errors
   - SSH and check `/var/log/syslog`

## Best Practices

1. **Always test in isolated environment**
   - Use unique deployment names
   - Deploy in separate project if possible

2. **Start small**
   - Test with 1 node first
   - Scale up gradually

3. **Monitor costs**
   - Set billing alerts
   - Use preemptible instances for testing

4. **Clean up after testing**
   - Always run `terraform destroy`
   - Verify all resources are removed

5. **Document test results**
   - Record deployment times
   - Note any issues encountered
   - Track resource usage