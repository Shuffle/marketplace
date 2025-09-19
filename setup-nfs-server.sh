#!/bin/bash
# Shuffle NFS Server Setup Script for Docker Swarm (NFSv3, pinned ports)

set -euo pipefail

echo "🔧 Setting up NFS server for Shuffle Docker Swarm (NFSv3, pinned ports)..."

export DEBIAN_FRONTEND=noninteractive

echo "📦 Installing NFS server packages..."
apt-get update -y
apt-get install -y nfs-kernel-server nfs-common rpcbind

echo "📁 Creating NFS share directories..."
install -d -m 0775 /srv/nfs/shuffle-apps
install -d -m 0775 /srv/nfs/shuffle-files
install -d -m 0775 /srv/nfs/shuffle-database
install -d -m 0755 /srv/nfs/nginx-config

# Choose a shared runtime UID:GID for write access (containers should run as this user)
APP_UID=${APP_UID:-1000}
APP_GID=${APP_GID:-1000}

echo "🔐 Setting ownership (UID:GID ${APP_UID}:${APP_GID}) and permissions..."
chown -R "${APP_UID}:${APP_GID}" /srv/nfs/shuffle-apps /srv/nfs/shuffle-files /srv/nfs/shuffle-database
chown -R "${APP_UID}:${APP_GID}" /srv/nfs/nginx-config || true
chmod -R u+rwX,g+rwX,o+rX /srv/nfs

# Optional: copy nginx config if present
if [ -f "./nginx-main.conf" ]; then
  echo "📋 Copying nginx configuration..."
  cp ./nginx-main.conf /srv/nfs/nginx-config/nginx.conf
  chown "${APP_UID}:${APP_GID}" /srv/nfs/nginx-config/nginx.conf
fi

# Detect primary IPv4 interface, IP and subnet
INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
SERVER_IP=$(ip -4 addr show "$INTERFACE" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
NETWORK=$(ip -4 route | awk -v IF="$INTERFACE" '$3==IF && $1 ~ /\// && $1!="default" {print $1; exit}')

echo "🌐 Detected network: $NETWORK on interface $INTERFACE"
echo "🖥️  Server IP: $SERVER_IP"

echo "🛠️  Pinning NFSv3 helper ports..."
# nfsd: 2049, mountd: 51771, statd: 48095/48096, lockd: 32769
cat >/etc/nfs.conf <<'EOF'
[nfsd]
vers3=y
vers4=n
port=2049

[mountd]
port=51771

[statd]
port=48095
outgoing-port=48096

[lockd]
port=32769
EOF

# For some kernels, lockd also reads modprobe opts (harmless if duplicate)
cat >/etc/modprobe.d/lockd.conf <<'EOF'
options lockd nlm_tcpport=32769 nlm_udpport=32769
EOF

echo "📝 Configuring NFS exports (all_squash to UID:GID 1000 for Shuffle containers)..."
cat > /etc/exports <<EOF
# Shuffle NFS exports for Docker Swarm (NFSv3)
# Use all_squash with anonuid/anongid=1000 to match Shuffle container user
# This ensures all NFS operations are performed as UID:GID 1000:1000
# 'insecure' allows high (non-privileged) client ports used by Docker.
/srv/nfs/shuffle-apps      ${NETWORK}(rw,sync,all_squash,anonuid=${APP_UID},anongid=${APP_GID},no_subtree_check,insecure)
/srv/nfs/shuffle-files     ${NETWORK}(rw,sync,all_squash,anonuid=${APP_UID},anongid=${APP_GID},no_subtree_check,insecure)
/srv/nfs/shuffle-database  ${NETWORK}(rw,sync,all_squash,anonuid=${APP_UID},anongid=${APP_GID},no_subtree_check,insecure)
/srv/nfs/nginx-config      ${NETWORK}(ro,sync,all_squash,anonuid=${APP_UID},anongid=${APP_GID},no_subtree_check,insecure)
EOF

echo "🚀 Enabling and restarting NFS services..."
systemctl enable rpcbind nfs-kernel-server
systemctl restart rpcbind
systemctl restart nfs-kernel-server

echo "📤 Exporting NFS shares..."
exportfs -ra

echo "✅ NFS server setup complete! Current exports:"
exportfs -v

echo "🔎 RPC services (verify pinned ports):"
rpcinfo -p | egrep 'tcp.*(nfs|mountd|status|nlockmgr|portmapper)' || true

echo
echo "📋 NFS Share Information:"
echo "   shuffle-apps:      nfs://${SERVER_IP}/srv/nfs/shuffle-apps"
echo "   shuffle-files:     nfs://${SERVER_IP}/srv/nfs/shuffle-files"
echo "   shuffle-database:  nfs://${SERVER_IP}/srv/nfs/shuffle-database"
echo "   nginx-config:      nfs://${SERVER_IP}/srv/nfs/nginx-config"
echo
echo "🧪 Test from a worker node (manual):"
echo "  sudo mkdir -p /mnt/shuffle-apps"
echo "  sudo mount -o vers=3,proto=tcp,port=2049,mountport=51771,nolock ${SERVER_IP}:/srv/nfs/shuffle-apps /mnt/shuffle-apps"
echo "  # If you require POSIX locks, drop 'nolock' and open tcp/32769."
echo

echo "🧱 Firewall: allow TCP 2049, 111, 51771, 48095, 48096, 32769 from your Swarm nodes to ${SERVER_IP}"
echo "   (cloud + host firewall, if applicable)"

echo
echo "🔧 Applying OpenSearch optimizations..."
# Set ownership for database directory for Opensearch (UID 1000 typical)
chown -R 1000:1000 /srv/nfs/shuffle-database || true

# Disable swap (best-effort)
swapoff -a 2>/dev/null || echo "Swap already disabled"

# Set vm.max_map_count for OpenSearch
if [ "$(cat /proc/sys/vm/max_map_count)" -lt 262144 ]; then
  sysctl -w vm.max_map_count=262144
  if ! grep -q "^vm.max_map_count=" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
  fi
  echo "✅ vm.max_map_count set to 262144"
fi

echo "✅ OpenSearch optimizations applied"
