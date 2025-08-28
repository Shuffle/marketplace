#!/bin/bash
# Deploy resilience monitor to all manager nodes
set -euo pipefail

DEPLOYMENT_NAME="shuffle-test-deployment"

get_manager_nodes() {
    gcloud compute instances list \
        --filter="name~${DEPLOYMENT_NAME}-manager-.* AND status=RUNNING" \
        --format="csv[no-heading](name,zone)"
}

deploy_to_node() {
    local node=$1
    local zone=$2
    
    echo "Deploying resilience monitor to $node..."
    
    # Upload the script
    gcloud compute scp \
        /Users/aditya/Documents/OSS/marketplace/terraform/scripts/swarm_resilience_monitor.sh \
        "$node":/tmp/swarm_resilience_monitor.sh \
        --zone="$zone" \
        --ssh-flag="-o StrictHostKeyChecking=no" || return 1
    
    # Make it executable and move to proper location
    gcloud compute ssh "$node" --zone="$zone" \
        --ssh-flag="-o StrictHostKeyChecking=no" \
        --command="sudo chmod +x /tmp/swarm_resilience_monitor.sh && \
                   sudo mv /tmp/swarm_resilience_monitor.sh /opt/shuffle/swarm_resilience_monitor.sh" || return 1
    
    # Create systemd service
    gcloud compute ssh "$node" --zone="$zone" \
        --ssh-flag="-o StrictHostKeyChecking=no" \
        --command="sudo tee /etc/systemd/system/swarm-resilience.service > /dev/null << 'EOF'
[Unit]
Description=Swarm Resilience Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=root
ExecStart=/opt/shuffle/swarm_resilience_monitor.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF" || return 1
    
    # Start the service
    gcloud compute ssh "$node" --zone="$zone" \
        --ssh-flag="-o StrictHostKeyChecking=no" \
        --command="sudo systemctl daemon-reload && \
                   sudo systemctl enable swarm-resilience.service && \
                   sudo systemctl restart swarm-resilience.service" || return 1
    
    echo "✅ Successfully deployed to $node"
}

main() {
    echo "Deploying Swarm Resilience Monitor to all manager nodes..."
    
    while IFS=, read -r node zone; do
        if ! deploy_to_node "$node" "$zone"; then
            echo "❌ Failed to deploy to $node"
        fi
    done < <(get_manager_nodes)
    
    echo "Deployment complete!"
}

main "$@"