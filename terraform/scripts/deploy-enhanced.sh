#!/bin/bash
# Enhanced deploy.sh that properly sets OpenSearch environment variables based on cluster size

set -euo pipefail

# Get Swarm node count
SWARM_NODE_COUNT=$(docker node ls --format "{{.ID}}" | wc -l)
echo "Detected ${SWARM_NODE_COUNT} Swarm nodes"

# Set OpenSearch configuration based on node count
if [[ "${SWARM_NODE_COUNT}" -eq 1 ]]; then
    # Single node configuration
    export OPENSEARCH_REPLICAS=1
    export OPENSEARCH_INDEX_REPLICAS=0
    export OPENSEARCH_DISCOVERY_TYPE="single-node"
    export OPENSEARCH_INITIAL_MASTERS="shuffle-opensearch-1"
    export OPENSEARCH_JAVA_OPTS="-Xms2g -Xmx2g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
else
    # Multi-node cluster configuration
    export OPENSEARCH_REPLICAS="${SWARM_NODE_COUNT}"
    if [[ "${OPENSEARCH_REPLICAS}" -gt 3 ]]; then
        export OPENSEARCH_REPLICAS=3
    fi
    export OPENSEARCH_INDEX_REPLICAS=$(( OPENSEARCH_REPLICAS - 1 ))
    export OPENSEARCH_DISCOVERY_TYPE="zen"
    
    # Generate initial masters list
    export OPENSEARCH_INITIAL_MASTERS=""
    for i in $(seq 1 $OPENSEARCH_REPLICAS); do
        if [[ -z "${OPENSEARCH_INITIAL_MASTERS}" ]]; then
            OPENSEARCH_INITIAL_MASTERS="shuffle-opensearch-${i}"
        else
            OPENSEARCH_INITIAL_MASTERS="${OPENSEARCH_INITIAL_MASTERS},shuffle-opensearch-${i}"
        fi
    done
    
    # Adjust memory based on cluster size
    if [[ "${SWARM_NODE_COUNT}" -eq 2 ]]; then
        export OPENSEARCH_JAVA_OPTS="-Xms3g -Xmx3g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
    else
        export OPENSEARCH_JAVA_OPTS="-Xms4g -Xmx4g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
    fi
fi

# Export Swarm node count for other services
export SWARM_NODE_COUNT

echo "OpenSearch Configuration:"
echo "  Replicas: ${OPENSEARCH_REPLICAS}"
echo "  Index Replicas: ${OPENSEARCH_INDEX_REPLICAS}"
echo "  Discovery Type: ${OPENSEARCH_DISCOVERY_TYPE}"
echo "  Initial Masters: ${OPENSEARCH_INITIAL_MASTERS}"
echo "  Java Opts: ${OPENSEARCH_JAVA_OPTS}"

# Append to .env file if not already present
if ! grep -q "OPENSEARCH_REPLICAS" .env 2>/dev/null; then
    cat >> .env <<EOF

# Dynamic OpenSearch Configuration
OPENSEARCH_REPLICAS=${OPENSEARCH_REPLICAS}
OPENSEARCH_INDEX_REPLICAS=${OPENSEARCH_INDEX_REPLICAS}
OPENSEARCH_DISCOVERY_TYPE=${OPENSEARCH_DISCOVERY_TYPE}
OPENSEARCH_INITIAL_MASTERS=${OPENSEARCH_INITIAL_MASTERS}
OPENSEARCH_JAVA_OPTS="${OPENSEARCH_JAVA_OPTS}"
SWARM_NODE_COUNT=${SWARM_NODE_COUNT}
EOF
fi

# Get NFS master IP
if [[ "${SWARM_NODE_COUNT}" -eq 1 ]]; then
    NFS_MASTER_IP=$(hostname -I | cut -d' ' -f1)
else
    # For multi-node, get primary manager IP
    PRIMARY_MANAGER=$(docker node ls --filter role=manager --format "{{.Hostname}}" | head -1)
    NFS_MASTER_IP=$(docker node inspect ${PRIMARY_MANAGER} --format '{{.Status.Addr}}')
fi

export NFS_MASTER_IP
echo "NFS Master IP: ${NFS_MASTER_IP}"

# Update .env with NFS_MASTER_IP
if ! grep -q "NFS_MASTER_IP" .env 2>/dev/null; then
    echo "NFS_MASTER_IP=${NFS_MASTER_IP}" >> .env
fi

# Deploy the stack
echo "Deploying Shuffle stack..."
docker stack deploy -c swarm-nfs.yaml shuffle

echo "Stack deployed successfully!"
echo "Waiting for services to start..."
sleep 10

# Show service status
docker stack services shuffle