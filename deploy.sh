#!/bin/bash

# Shuffle Docker Swarm Deployment Script
# Automatically configures NFS and deploys the Shuffle stack

set -e

STACK_NAME="shuffle"
COMPOSE_FILE="swarm-nfs.yaml"
NFS_SETUP_SCRIPT="./setup-nfs-server.sh"

echo "🚀 Shuffle Docker Swarm Deployment"
echo "=================================="

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "❌ This script must be run with sudo privileges"
    echo "Usage: sudo ./deploy.sh"
    exit 1
fi

# Check if Docker Swarm is initialized
if ! docker node ls >/dev/null 2>&1; then
    echo "❌ Docker Swarm is not initialized"
    echo "Please run: docker swarm init"
    exit 1
fi

# Check if this is the manager node
if ! docker node ls --filter "role=manager" | grep -q "Leader"; then
    echo "❌ This script must be run on a Docker Swarm manager node"
    exit 1
fi

echo "✅ Docker Swarm manager node detected"

# Auto-detect the master node IP
echo "🔍 Auto-detecting master node IP..."
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
MASTER_IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)

if [ -z "$MASTER_IP" ]; then
    echo "❌ Could not auto-detect master node IP"
    exit 1
fi

echo "🖥️  Master node IP detected: $MASTER_IP"

# Check if NFS server is already running to avoid duplication
NFS_RUNNING=false
if systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
    if exportfs -v | grep -q "/srv/nfs/shuffle-apps"; then
        echo "✅ NFS server is already running with Shuffle exports"
        NFS_RUNNING=true
    fi
fi

# Setup NFS server if not already running
if [ "$NFS_RUNNING" = false ]; then
    echo "🔧 Setting up NFS server..."
    if [ -f "$NFS_SETUP_SCRIPT" ]; then
        chmod +x "$NFS_SETUP_SCRIPT"
        bash "$NFS_SETUP_SCRIPT"
        echo "✅ NFS server setup completed"
    else
        echo "❌ NFS setup script not found: $NFS_SETUP_SCRIPT"
        echo "Please ensure setup-nfs-server.sh is in the current directory"
        exit 1
    fi
else
    echo "⏭️  Skipping NFS setup (already configured)"
fi

# Create a backup and update the compose file directly
echo "📝 Updating compose file with master IP ($MASTER_IP)..."

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "❌ Compose file not found: $COMPOSE_FILE"
    exit 1
fi

# Create backup
cp "$COMPOSE_FILE" "${COMPOSE_FILE}.backup"

# Replace hardcoded IP with auto-detected master IP in original file
sed -i "s/addr=[0-9.]*,/addr=$MASTER_IP,/g; s/device=\"[0-9.]*:/device=\"$MASTER_IP:/g" "$COMPOSE_FILE"

echo "✅ Compose file updated with master IP"

# Deploy the stack
echo "🚢 Deploying Shuffle stack..."
if docker stack deploy -c "$COMPOSE_FILE" "$STACK_NAME"; then
    echo "✅ Stack deployment initiated successfully"
else
    echo "❌ Stack deployment failed"
    # Restore backup on failure
    cp "${COMPOSE_FILE}.backup" "$COMPOSE_FILE"
    exit 1
fi

# Clean up backup file
rm -f "${COMPOSE_FILE}.backup"

# Wait a moment for services to start
echo "⏳ Waiting for services to initialize..."
sleep 10

# Show stack status
echo "📊 Stack Status:"
docker stack services "$STACK_NAME" --format "table {{.Name}}\\t{{.Replicas}}\\t{{.Image}}"

echo ""
echo "🎉 Deployment Complete!"
echo "======================="
echo "Stack Name: $STACK_NAME"
echo "Master IP: $MASTER_IP"
echo ""
echo "📋 Access URLs:"
echo "   Frontend: http://$MASTER_IP:3001"
echo "   HTTPS: https://$MASTER_IP:3443"
echo "   OpenSearch: http://$MASTER_IP:9200"
echo ""
echo "🔧 Management Commands:"
echo "   View services: docker stack services $STACK_NAME"
echo "   View logs: docker service logs $STACK_NAME_<service-name>"
echo "   Remove stack: docker stack rm $STACK_NAME"
echo ""
echo "💡 Tip: Run 'docker stack services $STACK_NAME' to monitor service status"
