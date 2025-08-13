# Shuffle Docker Swarm Deployment Guide

This guide covers deploying Shuffle in a Docker Swarm cluster across multiple machines.

## Prerequisites

### Docker Swarm Setup (Multi-Machine)

Before deploying Shuffle, you need a properly configured Docker Swarm cluster:

1. **Initialize Swarm on Manager Node:**
   ```bash
   docker swarm init --advertise-addr <MANAGER_IP>
   ```

2. **Join Worker Nodes:**
   ```bash
   # On each worker node, run the join command from step 1 output
   docker swarm join --token <TOKEN> <MANAGER_IP>:2377
   ```

3. **Verify Cluster:**
   ```bash
   docker node ls
   ```

### Required Ports & Firewall Configuration

Docker Swarm requires specific ports for cluster communication. **These ports must be open between all swarm nodes:**

#### Docker Swarm Cluster Ports
- **TCP 2376**: Docker daemon API (if using TLS)
- **TCP 2377**: Docker swarm management traffic
- **TCP 7946**: Container network discovery
- **UDP 7946**: Container network discovery  
- **UDP 4789**: Overlay network traffic (VXLAN)

#### For GCP/Cloud Providers
Create firewall rules to allow these ports between swarm nodes:

```bash
# Docker Swarm cluster communication
gcloud compute firewall-rules create docker-swarm-cluster \
  --allow tcp:2376,tcp:2377,tcp:7946,udp:7946,udp:4789 \
  --source-tags docker-swarm \
  --target-tags docker-swarm \
  --description "Docker Swarm cluster communication"

# Tag your VMs
gcloud compute instances add-tags VM1 --tags docker-swarm
gcloud compute instances add-tags VM2 --tags docker-swarm
```

#### Application Ports
Expose these ports for external access to Shuffle:

```bash
# Shuffle application ports
gcloud compute firewall-rules create shuffle-app-ports \
  --allow tcp:3001,tcp:3443,tcp:9200,tcp:33333-33336 \
  --source-ranges 0.0.0.0/0 \
  --description "Shuffle application ports"
```

**Port Reference:**
- `3001`: Frontend HTTP
- `3443`: Frontend HTTPS  
- `9200`: OpenSearch
- `33333-33336`: Worker services

## Deployment Steps

1. **Clone the Repository:**
   ```bash
   git clone https://github.com/Shuffle/Shuffle.git
   cd Shuffle
   ```

2. **Configure Environment:**
   ```bash
   cp .env.example .env
   # Edit .env with your configuration
   ```

3. **Deploy Shuffle:**
   ```bash
   sudo ./deploy.sh
   ```

The deploy script will:
- Auto-detect the swarm manager IP
- Set up NFS for shared storage across nodes
- Deploy all Shuffle services
- Configure networking and load balancing

## Troubleshooting

### Network Issues
If services fail to start with "invalid config for network" errors:
1. Ensure all Docker Swarm ports are open between nodes
2. Remove the stack and redeploy: `docker stack rm shuffle && sudo ./deploy.sh`

### Service Status
Check service health:
```bash
docker service ls
docker service ps <service-name>
```

### Logs
View service logs:
```bash
docker service logs shuffle_<service-name>
```

## Access URLs

After successful deployment:
- **Frontend**: `http://<MASTER_IP>:3001`
- **HTTPS**: `https://<MASTER_IP>:3443`
- **OpenSearch**: `http://<MASTER_IP>:9200`

Replace `<MASTER_IP>` with your swarm manager's IP address.
