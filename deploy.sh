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

# Manager/Leader check
if ! docker node ls --filter "role=manager" | grep -q "Leader"; then
  echo "❌ This script must be run on a Docker Swarm manager node (Leader)"
  exit 1
fi
echo "✅ Docker Swarm manager (Leader) detected"

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
  echo "⏭️  Skipping NFS setup (already configured)"
fi

# Ensure compose file exists
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "❌ Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

# Export env var for compose substitution
export NFS_MASTER_IP="${MASTER_IP}"

# (Optional) write to a compose env file for transparency
echo "NFS_MASTER_IP=${NFS_MASTER_IP}" > .compose.env

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
echo "💡 Tip: IPs change? Just rerun this script — it will redeploy with the new NFS_MASTER_IP."
