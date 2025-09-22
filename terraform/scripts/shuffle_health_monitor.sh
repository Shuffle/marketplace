#!/bin/bash
# Shuffle Health Monitor - Ensures all services maintain correct replica count
# Auto-corrects common issues like NFS mount failures and load balancer problems

set -euo pipefail

LOG_FILE="/var/log/shuffle-health-monitor.log"
NGINX_CONFIG_PATH="/srv/nfs/nginx-config/nginx-main.conf"
LOCAL_NGINX_PATH="/opt/shuffle/nginx-main.conf"
CHECK_INTERVAL=30

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ensure_nginx_config() {
    # Check if nginx-config file exists locally or via NFS
    if [ ! -f "$NGINX_CONFIG_PATH" ] && [ -f "$LOCAL_NGINX_PATH" ]; then
        log_message "WARNING: NFS nginx config missing, copying from local backup"
        sudo mkdir -p /srv/nfs/nginx-config
        sudo cp "$LOCAL_NGINX_PATH" "$NGINX_CONFIG_PATH"
        sudo chown -R nobody:nogroup /srv/nfs/nginx-config
        sudo chmod 644 "$NGINX_CONFIG_PATH"
    fi
    
    # Always ensure we have a local backup
    if [ -f "$NGINX_CONFIG_PATH" ] && [ ! -f "$LOCAL_NGINX_PATH" ]; then
        sudo cp "$NGINX_CONFIG_PATH" "$LOCAL_NGINX_PATH"
    fi
    
    # If neither exists, create a basic nginx config
    if [ ! -f "$NGINX_CONFIG_PATH" ] && [ ! -f "$LOCAL_NGINX_PATH" ]; then
        log_message "ERROR: No nginx config found, creating default"
        cat > /tmp/nginx-main.conf << 'EOF'
user  nginx;
worker_processes  1;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    
    upstream frontend {
        server shuffle-frontend:80;
    }
    
    upstream backend {
        server shuffle_backend:5001;
    }
    
    server {
        listen       80;
        server_name  localhost;
        
        location / {
            proxy_pass http://frontend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        
        location /api/ {
            proxy_pass http://backend;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOF
        sudo cp /tmp/nginx-main.conf "$LOCAL_NGINX_PATH"
        sudo mkdir -p /srv/nfs/nginx-config
        sudo cp /tmp/nginx-main.conf "$NGINX_CONFIG_PATH"
        sudo chown -R nobody:nogroup /srv/nfs/nginx-config
        sudo chmod 644 "$NGINX_CONFIG_PATH"
    fi
}

fix_nfs_mount_issues() {
    local NODE_NAME=$(hostname)
    
    # Check if we're on a secondary node
    if [[ "$NODE_NAME" != *"manager-1"* ]]; then
        # Test NFS mount
        if ! timeout 5 ls /srv/nfs/nginx-config/ > /dev/null 2>&1; then
            log_message "NFS mount issue detected on $NODE_NAME"
            
            # Get primary manager IP - adjust this pattern to match your deployment name
            PRIMARY_IP=$(getent hosts $(hostname | sed 's/-[0-9]$/-1/') | awk '{ print $1 }' || echo "10.224.0.3")
            
            # Try to remount NFS
            sudo mkdir -p /srv/nfs/nginx-config
            sudo mount -t nfs -o nfsvers=3,proto=tcp,port=2049,mountport=51771,soft,intr,retrans=2 \
                ${PRIMARY_IP}:/srv/nfs/nginx-config /srv/nfs/nginx-config 2>/dev/null || true
            
            # If mount still fails, copy file locally
            if [ ! -f "$NGINX_CONFIG_PATH" ]; then
                log_message "NFS mount failed, using local workaround"
                sudo mkdir -p /srv/nfs/nginx-config
                
                # Try to get nginx config from primary via docker
                if docker node ls > /dev/null 2>&1; then
                    # We're in swarm, try to get from another node's container
                    docker run --rm -v nginx-config:/nginx-config:ro alpine cat /nginx-config/nginx-main.conf > /tmp/nginx-main.conf 2>/dev/null || true
                    if [ -s /tmp/nginx-main.conf ]; then
                        sudo cp /tmp/nginx-main.conf "$NGINX_CONFIG_PATH"
                    fi
                fi
                
                # Last resort: use local backup if available
                if [ ! -f "$NGINX_CONFIG_PATH" ] && [ -f "$LOCAL_NGINX_PATH" ]; then
                    sudo cp "$LOCAL_NGINX_PATH" "$NGINX_CONFIG_PATH"
                fi
            fi
        fi
    fi
}

check_load_balancer_health() {
    # Check if we're in a Docker Swarm
    if ! docker node ls > /dev/null 2>&1; then
        return 0
    fi
    
    # Get expected and actual replica count
    local EXPECTED_REPLICAS=$(docker node ls --format "{{.Status}}" | grep -c "Ready" || echo "1")
    local SERVICE_STATUS=$(docker service ls --format "{{.Name}} {{.Replicas}}" | grep "load-balancer" || echo "")
    
    if [ -z "$SERVICE_STATUS" ]; then
        log_message "ERROR: Load balancer service not found"
        return 1
    fi
    
    local ACTUAL_REPLICAS=$(echo "$SERVICE_STATUS" | awk '{print $2}' | cut -d'/' -f1 || echo "0")
    local TARGET_REPLICAS=$(echo "$SERVICE_STATUS" | awk '{print $2}' | cut -d'/' -f2 || echo "0")
    
    log_message "Load Balancer Status: $ACTUAL_REPLICAS/$TARGET_REPLICAS replicas running (Expected: $EXPECTED_REPLICAS)"
    
    # If not all replicas are running
    if [ "$ACTUAL_REPLICAS" != "$TARGET_REPLICAS" ] || [ "$ACTUAL_REPLICAS" != "$EXPECTED_REPLICAS" ]; then
        log_message "Load balancer replica mismatch detected. Attempting to fix..."
        
        # Ensure nginx config exists
        ensure_nginx_config
        fix_nfs_mount_issues
        
        # Check for failed tasks
        local FAILED_TASKS=$(docker service ps shuffle_load-balancer --format "{{.Node}} {{.CurrentState}}" | grep -i "failed" | wc -l || echo "0")
        if [ "$FAILED_TASKS" -gt 0 ]; then
            log_message "Found $FAILED_TASKS failed load balancer tasks"
            
            # Force update the service to restart failed tasks
            docker service update --force shuffle_load-balancer > /dev/null 2>&1 || true
            sleep 10
        fi
        
        # If using global mode and still having issues, try to fix port conflicts
        if docker service inspect shuffle_load-balancer --format '{{.Spec.Mode}}' | grep -q "Global"; then
            # Check for port conflicts
            for port in 3001 3443; do
                # Find and kill any non-docker processes using the ports
                sudo lsof -i :$port | grep -v docker | awk 'NR>1 {print $2}' | xargs -r sudo kill -9 2>/dev/null || true
            done
        fi
    fi
}

check_memcached_config() {
    # Check if SHUFFLE_MEMCACHED is properly configured
    if [ -f /opt/shuffle/.env ]; then
        if ! grep -q "SHUFFLE_MEMCACHED=shuffle_memcached:11211" /opt/shuffle/.env; then
            log_message "Memcached not configured, fixing..."
            sudo sed -i 's/^SHUFFLE_MEMCACHED=$/SHUFFLE_MEMCACHED=shuffle_memcached:11211/' /opt/shuffle/.env
            
            # Restart backend services to pick up the change
            docker service update shuffle_backend --env-add "SHUFFLE_MEMCACHED=shuffle_memcached:11211" > /dev/null 2>&1 || true
            docker service update shuffle_orborus --env-add "SHUFFLE_MEMCACHED=shuffle_memcached:11211" > /dev/null 2>&1 || true
        fi
    fi
}

check_all_services() {
    if ! docker node ls > /dev/null 2>&1; then
        return 0
    fi
    
    # Check all critical services
    local SERVICES=("shuffle_backend" "shuffle_frontend" "shuffle_opensearch" "shuffle_orborus" "shuffle_memcached" "shuffle_load-balancer")
    
    for service in "${SERVICES[@]}"; do
        local SERVICE_STATUS=$(docker service ls --format "{{.Name}} {{.Replicas}}" | grep "^$service " || echo "")
        if [ -z "$SERVICE_STATUS" ]; then
            log_message "ERROR: Service $service not found"
            continue
        fi
        
        local CURRENT=$(echo "$SERVICE_STATUS" | awk '{print $2}' | cut -d'/' -f1)
        local TARGET=$(echo "$SERVICE_STATUS" | awk '{print $2}' | cut -d'/' -f2)
        
        if [ "$CURRENT" != "$TARGET" ]; then
            log_message "WARNING: $service has $CURRENT/$TARGET replicas"
            
            # Special handling for each service type
            case "$service" in
                "shuffle_opensearch")
                    # Check disk space
                    local DISK_USAGE=$(df /opt/shuffle/shuffle-database | tail -1 | awk '{print $5}' | sed 's/%//')
                    if [ "$DISK_USAGE" -gt 90 ]; then
                        log_message "ERROR: Disk usage critical at ${DISK_USAGE}%"
                        # Clean up old data if needed
                        docker exec $(docker ps -q -f name=opensearch) curl -X DELETE "localhost:9200/workflowexecution-*/_doc/_query" -H 'Content-Type: application/json' -d '{"query":{"range":{"started_at":{"lt":"now-30d"}}}}' 2>/dev/null || true
                    fi
                    ;;
                "shuffle_load-balancer")
                    # Already handled in check_load_balancer_health
                    ;;
                *)
                    # Generic restart for other services
                    docker service update --force "$service" > /dev/null 2>&1 || true
                    ;;
            esac
        fi
    done
}

# Main monitoring loop
main() {
    log_message "Starting Shuffle Health Monitor"
    
    # Initial checks
    ensure_nginx_config
    check_memcached_config
    
    while true; do
        # Run all checks
        check_load_balancer_health
        check_all_services
        fix_nfs_mount_issues
        
        # Sleep before next check
        sleep "$CHECK_INTERVAL"
    done
}

# Trap signals for clean shutdown
trap 'log_message "Monitor shutting down"; exit 0' SIGTERM SIGINT

# Run as daemon if not in foreground mode
if [ "${1:-}" != "foreground" ]; then
    # Check if already running
    if pgrep -f "shuffle_health_monitor.sh" | grep -v $$ > /dev/null; then
        echo "Monitor already running"
        exit 0
    fi
    
    # Run in background
    nohup "$0" foreground > /var/log/shuffle-health-monitor.log 2>&1 &
    echo "Shuffle Health Monitor started (PID: $!)"
else
    main
fi