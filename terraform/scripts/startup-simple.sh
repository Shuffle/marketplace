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
  echo "Secondary node initialization..."
  
  # Mount NFS if not primary
  if [[ "${IS_PRIMARY}" != "true" ]]; then
    echo "Waiting for primary manager to be ready..."
    
    # Wait for primary manager to set up NFS
    PRIMARY_IP=""
    for i in {1..60}; do
      PRIMARY_IP=$(gcloud compute instances describe ${DEPLOYMENT_NAME}-manager-1 \
        --zone=$(gcloud compute instances list --filter="name=${DEPLOYMENT_NAME}-manager-1" --format="value(zone)") \
        --format="get(networkInterfaces[0].networkIP)" 2>/dev/null || echo "")
      
      if [[ -n "${PRIMARY_IP}" ]]; then
        # Check if NFS is ready
        if showmount -e ${PRIMARY_IP} 2>/dev/null | grep -q shuffle-shared; then
          echo "Primary manager NFS is ready at ${PRIMARY_IP}"
          break
        fi
      fi
      
      echo "Waiting for primary manager NFS... (attempt $i/60)"
      sleep 5
    done
    
    if [[ -z "${PRIMARY_IP}" ]]; then
      echo "ERROR: Could not find primary manager IP"
      exit 1
    fi
    
    # Mount NFS share
    echo "Mounting NFS share from ${PRIMARY_IP}..."
    mount -t nfs ${PRIMARY_IP}:/var/lib/shuffle-shared /var/lib/shuffle-shared
    
    # Add to fstab for persistence
    echo "${PRIMARY_IP}:/var/lib/shuffle-shared /var/lib/shuffle-shared nfs defaults 0 0" >> /etc/fstab
  fi
  
  # Join Docker Swarm
  if [[ "${NODE_ROLE}" == "manager" ]]; then
    echo "Joining swarm as manager..."
    
    # Wait for join token to be available
    for i in {1..60}; do
      if [[ -f /var/lib/shuffle-shared/manager-token ]] && [[ -f /var/lib/shuffle-shared/primary-ip ]]; then
        MANAGER_TOKEN=$(cat /var/lib/shuffle-shared/manager-token)
        SWARM_IP=$(cat /var/lib/shuffle-shared/primary-ip)
        
        if [[ -n "${MANAGER_TOKEN}" ]] && [[ -n "${SWARM_IP}" ]]; then
          echo "Found swarm join information"
          break
        fi
      fi
      
      echo "Waiting for swarm join token... (attempt $i/60)"
      sleep 5
    done
    
    if [[ -z "${MANAGER_TOKEN}" ]] || [[ -z "${SWARM_IP}" ]]; then
      echo "ERROR: Could not get swarm join information"
      exit 1
    fi
    
    # Join the swarm as manager
    docker swarm join --token ${MANAGER_TOKEN} ${SWARM_IP}:2377
    
    echo "Successfully joined swarm as manager"
    
    # Download and setup Shuffle files for this manager
    cd /opt/shuffle
    
    # Download Shuffle deployment files
    curl -o deploy.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/deploy.sh
    curl -o swarm-nfs.yaml https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/swarm.yaml
    curl -o setup-nfs-server.sh https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/setup-nfs-server.sh
    curl -o .env https://raw.githubusercontent.com/Shuffle/marketplace/refs/heads/master/.env
    
    chmod +x deploy.sh setup-nfs-server.sh
    
    # Wait a bit for swarm to stabilize
    sleep 10
    
    # Deploy Shuffle stack (this will update the existing stack if already deployed)
    echo "Running deploy.sh on manager node..."
    ./deploy.sh
    
    echo "Manager node initialization complete!"
    
  elif [[ "${NODE_ROLE}" == "worker" ]]; then
    echo "Joining swarm as worker..."
    
    # Wait for join token to be available
    for i in {1..60}; do
      if [[ -f /var/lib/shuffle-shared/worker-token ]] && [[ -f /var/lib/shuffle-shared/primary-ip ]]; then
        WORKER_TOKEN=$(cat /var/lib/shuffle-shared/worker-token)
        SWARM_IP=$(cat /var/lib/shuffle-shared/primary-ip)
        
        if [[ -n "${WORKER_TOKEN}" ]] && [[ -n "${SWARM_IP}" ]]; then
          echo "Found swarm join information"
          break
        fi
      fi
      
      echo "Waiting for swarm join token... (attempt $i/60)"
      sleep 5
    done
    
    if [[ -z "${WORKER_TOKEN}" ]] || [[ -z "${SWARM_IP}" ]]; then
      echo "ERROR: Could not get swarm join information"
      exit 1
    fi
    
    # Join the swarm as worker
    docker swarm join --token ${WORKER_TOKEN} ${SWARM_IP}:2377
    
    echo "Successfully joined swarm as worker"
  fi
fi

# Run database permissions monitor in background
echo "Starting database permissions monitor..."
cat > /opt/shuffle/monitor-db-permissions.sh << 'EOF'
#!/bin/bash

# Monitor and fix permissions for /opt/shuffle/shuffle-database directory
# This script runs perpetually checking every 5 seconds until the directory
# exists with correct permissions (owned by 1000:1000)

SHUFFLE_DB_DIR="/opt/shuffle/shuffle-database"
TARGET_UID=1000
TARGET_GID=1000
CHECK_INTERVAL=5

echo "[$(date)] Starting shuffle-database permissions monitor..."

while true; do
    if [ -d "$SHUFFLE_DB_DIR" ]; then
        # Get current ownership
        CURRENT_UID=$(stat -c %u "$SHUFFLE_DB_DIR" 2>/dev/null)
        CURRENT_GID=$(stat -c %g "$SHUFFLE_DB_DIR" 2>/dev/null)
        
        if [ "$CURRENT_UID" = "$TARGET_UID" ] && [ "$CURRENT_GID" = "$TARGET_GID" ]; then
            echo "[$(date)] Directory $SHUFFLE_DB_DIR exists with correct permissions (1000:1000). Exiting."
            exit 0
        else
            echo "[$(date)] Fixing permissions for $SHUFFLE_DB_DIR (current: $CURRENT_UID:$CURRENT_GID, target: $TARGET_UID:$TARGET_GID)"
            sudo chown 1000:1000 -R "$SHUFFLE_DB_DIR"
            
            # Verify the change
            NEW_UID=$(stat -c %u "$SHUFFLE_DB_DIR" 2>/dev/null)
            NEW_GID=$(stat -c %g "$SHUFFLE_DB_DIR" 2>/dev/null)
            
            if [ "$NEW_UID" = "$TARGET_UID" ] && [ "$NEW_GID" = "$TARGET_GID" ]; then
                echo "[$(date)] Permissions successfully updated to 1000:1000. Exiting."
                exit 0
            else
                echo "[$(date)] Warning: Failed to update permissions. Will retry in $CHECK_INTERVAL seconds."
            fi
        fi
    else
        echo "[$(date)] Directory $SHUFFLE_DB_DIR does not exist yet. Checking again in $CHECK_INTERVAL seconds..."
    fi
    
    sleep $CHECK_INTERVAL
done
EOF

chmod +x /opt/shuffle/monitor-db-permissions.sh
nohup /opt/shuffle/monitor-db-permissions.sh > /var/log/shuffle-db-monitor.log 2>&1 &
echo "Database permissions monitor started (PID: $!)"

echo "Node initialization complete!"
echo "Services status:"
if [[ "${IS_PRIMARY}" == "true" ]]; then
  sleep 5
  docker stack services shuffle 2>/dev/null || echo "Stack not yet ready"
fi