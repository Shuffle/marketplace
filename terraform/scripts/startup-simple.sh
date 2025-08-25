#!/bin/bash
set -euo pipefail

echo "Starting Shuffle node initialization..."

# Get metadata
METADATA_URL="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
METADATA_HEADER="Metadata-Flavor: Google"
PROJECT_ID=$(curl -s "http://metadata.google.internal/computeMetadata/v1/project/project-id" -H "Metadata-Flavor: Google")

get_metadata() {
  curl -s "${METADATA_URL}/${1}" -H "${METADATA_HEADER}" || echo ""
}

NODE_ROLE=$(get_metadata "node-role")
IS_PRIMARY=$(get_metadata "is-primary")
DEPLOYMENT_NAME=$(get_metadata "deployment-name")
TOTAL_NODES=$(get_metadata "total-nodes")

echo "Node Configuration:"
echo "  Role: ${NODE_ROLE}"
echo "  Is Primary: ${IS_PRIMARY}"
echo "  Deployment: ${DEPLOYMENT_NAME}"
echo "  Total Nodes: ${TOTAL_NODES}"

# Update system and install dependencies
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    nfs-common \
    nfs-kernel-server \
    jq \
    netcat

# Install Docker if not present
if ! command -v docker &> /dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi

# Setup directories
mkdir -p /opt/shuffle
mkdir -p /opt/shuffle/shuffle-database
chown 1000:1000 /opt/shuffle/shuffle-database
chmod 755 /opt/shuffle/shuffle-database
echo "Created /opt/shuffle/shuffle-database with correct permissions"

# For single node deployment, always make it the primary
if [[ "${TOTAL_NODES}" == "1" ]]; then
  IS_PRIMARY="true"
  NODE_ROLE="manager"
fi

if [[ "${NODE_ROLE}" == "manager" ]] && [[ "${IS_PRIMARY}" == "true" ]]; then
  echo "Initializing primary manager node..."
  
  # Initialize Docker Swarm
  MY_IP=$(hostname -I | cut -d' ' -f1)
  docker swarm init --advertise-addr ${MY_IP}
  
  echo "Docker Swarm initialized. Manager token available via: docker swarm join-token manager"
  
  # Download and setup Shuffle files
  cd /opt/shuffle
  
  # Download Shuffle deployment files
  curl -o deploy.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/deploy.sh
  # Use our local fixed swarm.yaml instead of downloading the remote buggy one
  curl -o swarm-nfs.yaml https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/swarm.yaml
  curl -o setup-nfs-server.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/setup-nfs-server.sh
  curl -o .env https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/.env
   
  chmod +x deploy.sh setup-nfs-server.sh
  
  # Download nginx configuration
  mkdir -p /srv/nfs/nginx-config
  curl -o /srv/nfs/nginx-config/nginx-main.conf https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/nginx-main.conf
  
  # Wait a bit for swarm to stabilize
  sleep 10
  
  # Deploy Shuffle stack using the deploy script
  echo "Deploying Shuffle stack..."
  ./deploy.sh
  
  echo "Primary manager initialization complete!"
  
else
  echo "Secondary manager node initialization..."
  
  # Get primary manager details
  echo "Getting primary manager information..."
  PRIMARY_ZONE=$(gcloud compute instances list --filter="name=${DEPLOYMENT_NAME}-manager-1" --format="value(zone)")
  PRIMARY_IP=$(gcloud compute instances describe ${DEPLOYMENT_NAME}-manager-1 --zone=${PRIMARY_ZONE} --format="get(networkInterfaces[0].networkIP)")
  
  if [[ -z "${PRIMARY_IP}" ]]; then
    echo "ERROR: Could not find primary manager IP"
    exit 1
  fi
  
  echo "Primary manager IP: ${PRIMARY_IP}"
  
  # Wait for primary manager to initialize Docker Swarm
  echo "Waiting for primary manager to initialize swarm..."
  for i in {1..60}; do
    # Try to get the join token from the primary via SSH with proper flags
    MANAGER_TOKEN=$(gcloud compute ssh ${DEPLOYMENT_NAME}-manager-1 --zone=${PRIMARY_ZONE} --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o UserKnownHostsFile=/dev/null" --command="sudo docker swarm join-token manager -q" 2>/dev/null || echo "")
    
    # Validate the token format
    if [[ -n "${MANAGER_TOKEN}" ]] && [[ "${MANAGER_TOKEN}" == SWMTKN-* ]]; then
      echo "Got valid swarm manager join token: ${MANAGER_TOKEN:0:20}..."
      break
    fi
    
    echo "Waiting for swarm to be initialized... (attempt $i/60)"
    sleep 10
  done
  
  if [[ -z "${MANAGER_TOKEN}" ]]; then
    echo "ERROR: Could not get swarm join token from primary"
    exit 1
  fi
  
  # Join the swarm as manager
  echo "Joining swarm as manager..."
  echo "Token: ${MANAGER_TOKEN:0:20}..."
  echo "Primary IP: ${PRIMARY_IP}"
  
  if docker swarm join --token "${MANAGER_TOKEN}" "${PRIMARY_IP}:2377"; then
    echo "Successfully joined swarm as manager"
  else
    echo "ERROR: Failed to join swarm. Retrying..."
    sleep 10
    docker swarm join --token "${MANAGER_TOKEN}" "${PRIMARY_IP}:2377" || {
      echo "ERROR: Failed to join swarm after retry"
      exit 1
    }
  fi
  
  # Download and setup Shuffle files for this manager
  cd /opt/shuffle
  
  # Download Shuffle deployment files
  curl -o deploy.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/deploy.sh
  # Use our local fixed swarm.yaml instead of downloading the remote buggy one
  curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/swarm-yaml" > ./swarm-nfs.yaml
  curl -o setup-nfs-server.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/setup-nfs-server.sh
  curl -o .env https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/.env
  
  chmod +x deploy.sh setup-nfs-server.sh
  
  # Wait a bit for swarm to stabilize
  sleep 10
  
  # Deploy Shuffle stack (this will update the existing stack if already deployed)
  echo "Running deploy.sh on manager node..."
  ./deploy.sh
  
  echo "Manager node initialization complete!"
fi

# Run database permissions monitor in background
echo "Starting database permissions monitor..."
wget -O /opt/shuffle/monitor-db-permissions.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/terraform/scripts/monitor-db-permissions.sh
chmod +x /opt/shuffle/monitor-db-permissions.sh
nohup /opt/shuffle/monitor-db-permissions.sh > /var/log/shuffle-db-monitor.log 2>&1 &
echo "Database permissions monitor started (PID: $!)"

echo "Node initialization complete!"
echo "Services status:"
if [[ "${IS_PRIMARY}" == "true" ]]; then
  sleep 5
  docker stack services shuffle 2>/dev/null || echo "Stack not yet ready"
fi