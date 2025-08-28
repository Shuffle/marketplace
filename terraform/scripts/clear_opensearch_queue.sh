#!/bin/bash
# Clear OpenSearch queues from accessible nodes
set -euo pipefail

echo "Clearing OpenSearch queues..."

NODES=(
    "shuffle-test-deployment-manager-1:australia-southeast1-a"
    "shuffle-test-deployment-manager-2:australia-southeast1-b" 
    "shuffle-test-deployment-manager-3:australia-southeast1-c"
)

for node_info in "${NODES[@]}"; do
    IFS=':' read -r node zone <<< "$node_info"
    
    echo "Attempting to clear queue on $node..."
    
    # Try to flush and refresh indices
    if timeout 30 gcloud compute ssh "$node" --zone="$zone" --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o ConnectTimeout=10" --command="
        sudo docker ps --filter name=shuffle_opensearch --format '{{.Names}}' | head -1 | xargs -I {} sudo docker exec {} bash -c '
            curl -s -X POST \"localhost:9200/_flush/synced\" || true
            curl -s -X POST \"localhost:9200/_refresh\" || true
            curl -s -X POST \"localhost:9200/workflowexecution-*/_forcemerge?max_num_segments=1\" || true
            echo \"Queue operations attempted on $node\"
        '
    " 2>/dev/null; then
        echo "✅ Successfully processed $node"
    else
        echo "❌ Failed to access $node (timeout/unreachable)"
    fi
done

echo "Queue clearing attempts complete"