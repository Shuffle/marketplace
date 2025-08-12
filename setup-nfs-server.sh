#!/bin/bash

# Shuffle NFS Server Setup Script for Docker Swarm Master Node
# This script sets up an NFS server to share Docker volumes across swarm nodes

set -e

echo "Setting up NFS server for Shuffle Docker Swarm..."

# Install NFS server
echo "Installing NFS server packages..."
apt-get update
apt-get install -y nfs-kernel-server nfs-common

# Create directories for NFS shares that users can write to
echo "Creating NFS share directories..."
mkdir -p /srv/nfs/shuffle-apps
mkdir -p /srv/nfs/shuffle-files
mkdir -p /srv/nfs/shuffle-database
mkdir -p /srv/nfs/nginx-config

# Set proper ownership and permissions for user access
echo "Setting permissions for user access..."
chown -R $SUDO_USER:$SUDO_USER /srv/nfs/
chmod -R 755 /srv/nfs/

# Copy nginx config if it exists
if [ -f "./nginx-main.conf" ]; then
    echo "📋 Copying nginx configuration..."
    cp ./nginx-main.conf /srv/nfs/nginx-config/nginx.conf
    chown $SUDO_USER:$SUDO_USER /srv/nfs/nginx-config/nginx.conf
fi

# Get the current network interface and IP
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
SERVER_IP=$(ip addr show $INTERFACE | grep "inet " | awk '{print $2}' | cut -d/ -f1 | head -n1)
NETWORK=$(ip route | grep $INTERFACE | grep "/" | grep -v default | awk '{print $1}' | head -n1)

echo "Detected network: $NETWORK on interface $INTERFACE"
echo "Server IP: $SERVER_IP"

# Configure NFS exports
echo "Configuring NFS exports..."
cat > /etc/exports << EOF
# Shuffle NFS exports for Docker Swarm
# Allow access from the local network with read-write permissions
/srv/nfs/shuffle-apps    $NETWORK(rw,sync,no_subtree_check,no_root_squash,insecure)
/srv/nfs/shuffle-files   $NETWORK(rw,sync,no_subtree_check,no_root_squash,insecure)  
/srv/nfs/shuffle-database $NETWORK(rw,sync,no_subtree_check,no_root_squash,insecure)
/srv/nfs/nginx-config    $NETWORK(ro,sync,no_subtree_check,no_root_squash,insecure)
EOF

# Start and enable NFS services
echo "Starting NFS services..."
systemctl enable nfs-kernel-server
systemctl restart nfs-kernel-server
systemctl enable rpcbind
systemctl restart rpcbind

# Export the filesystems
echo "Exporting NFS shares..."
exportfs -ra

# Show the exports
echo "NFS server setup complete! Current exports:"
exportfs -v

echo ""
echo " NFS Share Information:"
echo "   shuffle-apps:     nfs://$SERVER_IP/srv/nfs/shuffle-apps"
echo "   shuffle-files:    nfs://$SERVER_IP/srv/nfs/shuffle-files"  
echo "   shuffle-database: nfs://$SERVER_IP/srv/nfs/shuffle-database"
echo "   nginx-config:     nfs://$SERVER_IP/srv/nfs/nginx-config"
echo ""
echo " To mount on worker nodes, run:"
echo "   sudo mount -t nfs $SERVER_IP:/srv/nfs/shuffle-apps /mnt/shuffle-apps"
echo ""
echo " User-writable directories created at:"
echo "   /srv/nfs/shuffle-apps"
echo "   /srv/nfs/shuffle-files"
echo "   /srv/nfs/shuffle-database"
echo "   /srv/nfs/nginx-config"

# Apply OpenSearch optimizations
echo ""
echo "Applying OpenSearch optimizations..."

# Set ownership for database directory
chown -R 1000:1000 /srv/nfs/shuffle-database

# Disable swap
swapoff -a 2>/dev/null || echo "Swap already disabled"

# Set vm.max_map_count for OpenSearch
if [ "$(cat /proc/sys/vm/max_map_count)" -lt 262144 ]; then
    sysctl -w vm.max_map_count=262144
    if ! grep -q "vm.max_map_count" /etc/sysctl.conf; then
        echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    fi
    echo "vm.max_map_count set to 262144"
fi

echo "✅ OpenSearch optimizations applied"
