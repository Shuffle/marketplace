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
mkdir -p /var/lib/shuffle-shared

# For single node deployment, always make it the primary
if [[ "${TOTAL_NODES}" == "1" ]]; then
  IS_PRIMARY="true"
  NODE_ROLE="manager"
fi

if [[ "${NODE_ROLE}" == "manager" ]] && [[ "${IS_PRIMARY}" == "true" ]]; then
  echo "Initializing primary manager node..."
  
  # Setup NFS server
  mkdir -p /etc/exports.d
  echo "/var/lib/shuffle-shared ${DEPLOYMENT_NAME}-*(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports.d/shuffle-shared.exports
  systemctl enable nfs-kernel-server
  systemctl restart nfs-kernel-server
  exportfs -a
  
  # Initialize Docker Swarm
  MY_IP=$(hostname -I | cut -d' ' -f1)
  docker swarm init --advertise-addr ${MY_IP}
  
  # Save join tokens
  docker swarm join-token manager -q > /var/lib/shuffle-shared/manager-token
  docker swarm join-token worker -q > /var/lib/shuffle-shared/worker-token
  echo ${MY_IP} > /var/lib/shuffle-shared/primary-ip
  
  # Download and setup Shuffle files
  cd /opt/shuffle
  
  # Download Shuffle deployment files
  curl -o deploy.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/deploy.sh
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
  echo "Secondary node initialization (not yet implemented for this test)..."
  # For now, just install dependencies
  echo "Node ready for future swarm join"
fi

echo "Node initialization complete!"
echo "Services status:"
if [[ "${IS_PRIMARY}" == "true" ]]; then
  sleep 5
  docker stack services shuffle 2>/dev/null || echo "Stack not yet ready"
fi