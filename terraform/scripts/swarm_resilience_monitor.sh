#!/bin/bash
# Swarm Resilience Monitor - handles automatic failover and recovery
set -euo pipefail

LOG_FILE="/var/log/swarm-resilience.log"
QUORUM_CHECK_INTERVAL=30  # seconds
HEALTH_CHECK_INTERVAL=60  # seconds

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_swarm_health() {
    # Check if we can communicate with swarm
    if ! docker node ls >/dev/null 2>&1; then
        return 1
    fi
    
    # Check if we have quorum
    local manager_count=$(docker node ls --filter "role=manager" --format "table {{.Status}}" | grep -c "Ready" || true)
    local total_managers=$(docker node ls --filter "role=manager" --format "table {{.ID}}" | wc -l)
    
    # Need majority for quorum (2 out of 3, 3 out of 5, etc.)
    local required_quorum=$(( (total_managers / 2) + 1 ))
    
    if [ "$manager_count" -lt "$required_quorum" ]; then
        log "WARNING: Only $manager_count/$total_managers managers available, need $required_quorum for quorum"
        return 1
    fi
    
    return 0
}

recover_from_split_brain() {
    log "Attempting split-brain recovery..."
    
    # Get our node ID and IP
    local node_id=$(hostname)
    local node_ip=$(hostname -I | cut -d' ' -f1)
    
    # Try to force new cluster if we're the only one left
    local available_managers=$(gcloud compute instances list --filter="name~.*manager.* AND status=RUNNING" --format="value(name)" | wc -l)
    
    if [ "$available_managers" -eq 1 ]; then
        log "We are the only manager available, forcing new cluster"
        docker swarm init --force-new-cluster --advertise-addr "$node_ip"
        
        # Wait for cluster to stabilize
        sleep 10
        
        # Restart critical services
        restart_critical_services
        return 0
    fi
    
    return 1
}

restart_critical_services() {
    log "Restarting critical services after swarm recovery"
    
    # List of critical services that must be running
    local critical_services=(
        "shuffle_backend"
        "shuffle_frontend" 
        "shuffle_opensearch"
        "opensearch-circuit-breaker"
    )
    
    for service in "${critical_services[@]}"; do
        if docker service ls --filter "name=$service" --format "{{.Name}}" | grep -q "$service"; then
            log "Updating service: $service"
            docker service update --force --detach "$service" || true
        else
            log "WARNING: Critical service $service not found"
        fi
    done
}

check_service_health() {
    # Check if critical services are running with correct replica counts
    local failed_services=()
    
    while read -r service replicas; do
        local running=$(echo "$replicas" | cut -d'/' -f1)
        local desired=$(echo "$replicas" | cut -d'/' -f2)
        
        if [ "$running" != "$desired" ]; then
            failed_services+=("$service")
            log "Service $service has $running/$desired replicas running"
        fi
    done < <(docker service ls --format "{{.Name}} {{.Replicas}}")
    
    if [ ${#failed_services[@]} -gt 0 ]; then
        log "Found ${#failed_services[@]} services with replica issues"
        return 1
    fi
    
    return 0
}

auto_scale_on_failure() {
    log "Checking if we need to adjust replica counts due to node failures"
    
    local available_nodes=$(docker node ls --filter "availability=active" --format "{{.Hostname}}" | wc -l)
    
    # If we only have 1 node, scale down services that require multiple nodes
    if [ "$available_nodes" -eq 1 ]; then
        log "Only 1 node available, scaling down distributed services"
        
        # Scale down services that can't run on single node
        docker service scale shuffle_backend=1 2>/dev/null || true
        docker service scale shuffle_frontend=1 2>/dev/null || true
        docker service scale shuffle_opensearch=1 2>/dev/null || true
    fi
}

main() {
    log "Starting Swarm Resilience Monitor"
    
    while true; do
        if ! check_swarm_health; then
            log "Swarm health check failed, attempting recovery"
            
            if recover_from_split_brain; then
                log "Split-brain recovery successful"
            else
                log "Could not recover from split-brain, will retry"
            fi
            
            sleep "$QUORUM_CHECK_INTERVAL"
            continue
        fi
        
        # Swarm is healthy, check service health
        if ! check_service_health; then
            log "Service health issues detected"
            auto_scale_on_failure
        fi
        
        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

# Handle signals gracefully
trap 'log "Swarm resilience monitor shutting down"; exit 0' SIGTERM SIGINT

# Start monitoring
main