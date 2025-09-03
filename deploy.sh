#!/bin/bash
# Shuffle Docker Swarm Deployment Script
# Automatically configures NFS and deploys the Shuffle stack

set -euo pipefail

STACK_NAME="shuffle"
COMPOSE_FILE="swarm-nfs.yaml"
NFS_SETUP_SCRIPT="./setup-nfs-server.sh"

echo "🚀 Shuffle Docker Swarm Deployment"
echo "=================================="

# Require sudo/root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "❌ This script must be run with sudo privileges"
  echo "Usage: sudo ./deploy.sh"
  exit 1
fi

# Swarm check
if ! docker node ls >/dev/null 2>&1; then
  echo "❌ Docker Swarm is not initialized"
  echo "Please run: docker swarm init"
  exit 1
fi

# Manager check
if ! docker node ls --filter "role=manager" | grep -q "$(hostname)"; then
  echo "❌ This script must be run on a Docker Swarm manager node"
  exit 1
fi
echo "✅ Docker Swarm manager detected"

# Detect primary interface and IP
echo "🔍 Auto-detecting master node IP..."
DEFAULT_IFACE="$(ip route show default | awk '/default/ {print $5; exit}')"
if [[ -z "${DEFAULT_IFACE}" ]]; then
  echo "❌ Could not detect default network interface"
  exit 1
fi

MASTER_IP="$(ip -4 addr show "$DEFAULT_IFACE" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)"
if [[ -z "${MASTER_IP}" ]]; then
  echo "❌ Could not detect IP on interface ${DEFAULT_IFACE}"
  exit 1
fi
echo "🖥️  Master node IP detected: ${MASTER_IP}"

# Quick NFS presence check
NFS_RUNNING=false
if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
  if exportfs -v | grep -q "/srv/nfs/shuffle-apps"; then
    echo "✅ NFS server is already running with Shuffle exports"
    NFS_RUNNING=true
  fi
fi

# Setup NFS if needed
if [[ "${NFS_RUNNING}" == "false" ]]; then
  echo "🔧 Setting up NFS server..."
  if [[ -f "${NFS_SETUP_SCRIPT}" ]]; then
    chmod +x "${NFS_SETUP_SCRIPT}"
    bash "${NFS_SETUP_SCRIPT}"
    echo "✅ NFS server setup completed"
  else
    echo "❌ NFS setup script not found: ${NFS_SETUP_SCRIPT}"
    echo "Please ensure setup-nfs-server.sh is in the current directory"
    exit 1
  fi
else
  echo "✅ NFS server already running"
fi

# Setup local OpenSearch data directories on all nodes
echo "🔧 Setting up local OpenSearch data directories on all nodes..."
for NODE_ID in $(docker node ls --format "{{.ID}}"); do
  NODE_HOSTNAME=$(docker node inspect "$NODE_ID" --format "{{.Description.Hostname}}")
  echo "  Setting up OpenSearch data directory on ${NODE_HOSTNAME}..."
  if [[ "$NODE_HOSTNAME" == "$(hostname)" ]]; then
    # Local node
    mkdir -p /opt/shuffle/shuffle-database
    chown -R 1000:1000 /opt/shuffle/shuffle-database
    chmod -R 755 /opt/shuffle/shuffle-database
  else
    # Remote node
    docker node update --label-add setup-opensearch-storage=pending "$NODE_ID"
  fi
done

# Ensure compose file exists
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "❌ Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

# Count swarm nodes for replica scaling
SWARM_NODE_COUNT=$(docker node ls --format "{{.ID}}" | wc -l)
echo "🔢 Detected ${SWARM_NODE_COUNT} nodes in the swarm"

# Generate OpenSearch initial master nodes list based on actual replicas
OPENSEARCH_REPLICAS=$(( SWARM_NODE_COUNT > 3 ? 3 : SWARM_NODE_COUNT ))
OPENSEARCH_INDEX_REPLICAS=$(( OPENSEARCH_REPLICAS - 1 ))
OPENSEARCH_INITIAL_MASTERS=""
for i in $(seq 1 $OPENSEARCH_REPLICAS); do
  if [[ -z "${OPENSEARCH_INITIAL_MASTERS}" ]]; then
    OPENSEARCH_INITIAL_MASTERS="shuffle-opensearch-${i}"
  else
    OPENSEARCH_INITIAL_MASTERS="${OPENSEARCH_INITIAL_MASTERS},shuffle-opensearch-${i}"
  fi
done
echo "🔧 OpenSearch replicas: ${OPENSEARCH_REPLICAS}, index replicas: ${OPENSEARCH_INDEX_REPLICAS}, initial masters: ${OPENSEARCH_INITIAL_MASTERS}"

# Set OpenSearch 3.0 compatible configurations
# Set OpenSearch Java opts based on node count
if [[ "${SWARM_NODE_COUNT}" -eq 1 ]]; then
    OPENSEARCH_JAVA_OPTS="-Xms1g -Xmx1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
    echo "🔧 Single-node deployment"
elif [[ "${SWARM_NODE_COUNT}" -eq 2 ]]; then
    OPENSEARCH_JAVA_OPTS="-Xms3g -Xmx3g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
    echo "🔧 Multi-node deployment: 2 nodes"
else
    OPENSEARCH_JAVA_OPTS="-Xms4g -Xmx4g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
    echo "🔧 Multi-node deployment: ${SWARM_NODE_COUNT} nodes"
fi
echo "🔧 OpenSearch cluster configuration handled by swarm.yaml"

echo "🔧 OpenSearch Java opts: ${OPENSEARCH_JAVA_OPTS}"

# Calculate dynamic thread pool settings based on node count and resources
# Search threads: 1-3 per node, max 12
THREAD_POOL_SEARCH_SIZE=$(( SWARM_NODE_COUNT > 4 ? 12 : SWARM_NODE_COUNT * 3 ))
THREAD_POOL_SEARCH_QUEUE=$(( THREAD_POOL_SEARCH_SIZE * 1000 ))

# Write threads: 1-2 per node, max 8  
THREAD_POOL_WRITE_SIZE=$(( SWARM_NODE_COUNT > 4 ? 8 : SWARM_NODE_COUNT * 2 ))
THREAD_POOL_WRITE_QUEUE=$(( THREAD_POOL_WRITE_SIZE * 500 ))

# Get threads: 1-2 per node, max 6
THREAD_POOL_GET_SIZE=$(( SWARM_NODE_COUNT > 3 ? 6 : SWARM_NODE_COUNT * 2 ))
THREAD_POOL_GET_QUEUE=$(( THREAD_POOL_GET_SIZE * 1000 ))

# Dynamic circuit breaker settings based on cluster size
if [[ "${SWARM_NODE_COUNT}" -eq 1 ]]; then
    # More conservative for single node
    CIRCUIT_BREAKER_TOTAL_LIMIT="80%"
    CIRCUIT_BREAKER_REQUEST_LIMIT="50%"
    CIRCUIT_BREAKER_FIELDDATA_LIMIT="30%"
    CIRCUIT_BREAKER_NETWORK_LIMIT="50%"
elif [[ "${SWARM_NODE_COUNT}" -le 3 ]]; then
    # Moderate settings for small clusters
    CIRCUIT_BREAKER_TOTAL_LIMIT="85%"
    CIRCUIT_BREAKER_REQUEST_LIMIT="60%"
    CIRCUIT_BREAKER_FIELDDATA_LIMIT="40%"
    CIRCUIT_BREAKER_NETWORK_LIMIT="100%"
else
    # More aggressive for larger clusters with better fault tolerance
    CIRCUIT_BREAKER_TOTAL_LIMIT="90%"
    CIRCUIT_BREAKER_REQUEST_LIMIT="70%"
    CIRCUIT_BREAKER_FIELDDATA_LIMIT="50%"
    CIRCUIT_BREAKER_NETWORK_LIMIT="200%"
fi

echo "🔧 Thread pools - Search: ${THREAD_POOL_SEARCH_SIZE}, Write: ${THREAD_POOL_WRITE_SIZE}, Get: ${THREAD_POOL_GET_SIZE}"
echo "🔧 Circuit breakers - Total: ${CIRCUIT_BREAKER_TOTAL_LIMIT}, Request: ${CIRCUIT_BREAKER_REQUEST_LIMIT}"

# Export env vars for compose substitution
export NFS_MASTER_IP="${MASTER_IP}"
export SWARM_NODE_COUNT="${SWARM_NODE_COUNT}"
export OPENSEARCH_REPLICAS="${OPENSEARCH_REPLICAS}"
export OPENSEARCH_INDEX_REPLICAS="${OPENSEARCH_INDEX_REPLICAS}"
export OPENSEARCH_INITIAL_MASTERS="${OPENSEARCH_INITIAL_MASTERS}"
export OPENSEARCH_JAVA_OPTS="${OPENSEARCH_JAVA_OPTS}"

# Export dynamic thread pool settings
export THREAD_POOL_SEARCH_SIZE="${THREAD_POOL_SEARCH_SIZE}"
export THREAD_POOL_SEARCH_QUEUE="${THREAD_POOL_SEARCH_QUEUE}"
export THREAD_POOL_WRITE_SIZE="${THREAD_POOL_WRITE_SIZE}"
export THREAD_POOL_WRITE_QUEUE="${THREAD_POOL_WRITE_QUEUE}"
export THREAD_POOL_GET_SIZE="${THREAD_POOL_GET_SIZE}"
export THREAD_POOL_GET_QUEUE="${THREAD_POOL_GET_QUEUE}"

# Export dynamic circuit breaker settings
export CIRCUIT_BREAKER_TOTAL_LIMIT="${CIRCUIT_BREAKER_TOTAL_LIMIT}"
export CIRCUIT_BREAKER_REQUEST_LIMIT="${CIRCUIT_BREAKER_REQUEST_LIMIT}"
export CIRCUIT_BREAKER_FIELDDATA_LIMIT="${CIRCUIT_BREAKER_FIELDDATA_LIMIT}"
export CIRCUIT_BREAKER_NETWORK_LIMIT="${CIRCUIT_BREAKER_NETWORK_LIMIT}"

# Update existing .env file with deployment vars
if ! grep -q "^NFS_MASTER_IP=" .env 2>/dev/null; then
  echo "NFS_MASTER_IP=${NFS_MASTER_IP}" >> .env
else
  sed -i "s/^NFS_MASTER_IP=.*/NFS_MASTER_IP=${NFS_MASTER_IP}/" .env
fi

if ! grep -q "^SWARM_NODE_COUNT=" .env 2>/dev/null; then
  echo "SWARM_NODE_COUNT=${SWARM_NODE_COUNT}" >> .env
else
  sed -i "s/^SWARM_NODE_COUNT=.*/SWARM_NODE_COUNT=${SWARM_NODE_COUNT}/" .env
fi

if ! grep -q "^OPENSEARCH_REPLICAS=" .env 2>/dev/null; then
  echo "OPENSEARCH_REPLICAS=${OPENSEARCH_REPLICAS}" >> .env
else
  sed -i "s/^OPENSEARCH_REPLICAS=.*/OPENSEARCH_REPLICAS=${OPENSEARCH_REPLICAS}/" .env
fi

if ! grep -q "^OPENSEARCH_INDEX_REPLICAS=" .env 2>/dev/null; then
  echo "OPENSEARCH_INDEX_REPLICAS=${OPENSEARCH_INDEX_REPLICAS}" >> .env
else
  sed -i "s/^OPENSEARCH_INDEX_REPLICAS=.*/OPENSEARCH_INDEX_REPLICAS=${OPENSEARCH_INDEX_REPLICAS}/" .env
fi

if ! grep -q "^OPENSEARCH_INITIAL_MASTERS=" .env 2>/dev/null; then
  echo "OPENSEARCH_INITIAL_MASTERS=${OPENSEARCH_INITIAL_MASTERS}" >> .env
else
  sed -i "s/^OPENSEARCH_INITIAL_MASTERS=.*/OPENSEARCH_INITIAL_MASTERS=${OPENSEARCH_INITIAL_MASTERS}/" .env
fi

# Discovery type is now handled in the compose file directly

if ! grep -q "^OPENSEARCH_JAVA_OPTS=" .env 2>/dev/null; then
  echo "OPENSEARCH_JAVA_OPTS=${OPENSEARCH_JAVA_OPTS}" >> .env
else
  sed -i "s/^OPENSEARCH_JAVA_OPTS=.*/OPENSEARCH_JAVA_OPTS=${OPENSEARCH_JAVA_OPTS}/" .env
fi



# Check for network conflicts and recreate if needed
echo "🔍 Checking network configuration..."
EXISTING_SHUFFLE_NET=$(docker network inspect shuffle_shuffle 2>/dev/null || echo "null")
if [[ "${EXISTING_SHUFFLE_NET}" != "null" && "${EXISTING_SHUFFLE_NET}" != "[]" ]]; then
  CURRENT_SUBNET=$(echo "${EXISTING_SHUFFLE_NET}" | grep -o '"Subnet": "[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
  if [[ -n "${CURRENT_SUBNET}" && "${CURRENT_SUBNET}" != "10.224.0.0/16" ]]; then
    echo "🔧 Detected incompatible network configuration (${CURRENT_SUBNET}), recreating networks..."
    echo "⚠️  Temporarily removing stack to recreate networks with non-conflicting IP ranges..."
    #docker stack rm "${STACK_NAME}" 2>/dev/null || true
    #echo "⏳ Waiting for stack cleanup..."
    #sleep 20
    # Wait for networks to be fully removed
    #while docker network ls | grep -q "shuffle_shuffle"; do
    #  echo "⏳ Waiting for network cleanup to complete..."
    #  sleep 5
    #done
  fi
fi

# Deploy
echo "🚢 Deploying Shuffle stack..."
docker stack deploy --with-registry-auth --compose-file "${COMPOSE_FILE}" "${STACK_NAME}"

# Wait a moment for services to start
echo "⏳ Waiting for services to initialize..."
sleep 10

# Show stack status
echo "📊 Stack Status:"
docker stack services "${STACK_NAME}" --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}"

echo ""
echo "🎉 Deployment Complete!"
echo "======================="
echo "Stack Name: ${STACK_NAME}"
echo "Master IP: ${MASTER_IP}"
echo ""
echo "📋 Access URLs:"
echo "   Frontend:  http://${MASTER_IP}:3001"
echo "   HTTPS:     https://${MASTER_IP}:3443"
echo "   OpenSearch:http://${MASTER_IP}:9200"
echo ""
echo "🔧 Management Commands:"
echo "   View services: docker stack services ${STACK_NAME}"
echo "   View logs:     docker service logs ${STACK_NAME}_<service-name>"
echo "   Remove stack:  docker stack rm ${STACK_NAME}"
echo ""
echo "🏗️  Add Manager Node:"
MANAGER_TOKEN=$(docker swarm join-token manager -q)
echo "   On another machine: docker swarm join --token ${MANAGER_TOKEN} ${MASTER_IP}:2377"
echo "   Get current token: docker swarm join-token manager"
echo ""
echo "💡 Tip: IPs change? Just rerun this script — it will redeploy with the new NFS_MASTER_IP."
