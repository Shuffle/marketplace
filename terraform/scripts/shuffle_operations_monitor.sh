#!/bin/bash
# Shuffle Operations Monitor Script
# Monitors operation counts, execution statistics, and provides debugging info for stuck shuffle operations

set -euo pipefail

# Configuration
OPENSEARCH_URL="http://localhost:9200"
LOG_FILE="/var/log/shuffle-operations-monitor.log"
STATS_DIR="/var/log/shuffle-stats"
CONTAINER_PREFIX="shuffle_opensearch"
INTERVAL=5  # seconds between monitoring cycles

# Create stats directory
mkdir -p "$STATS_DIR"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d_%H-%M-%S'
}

# Function to query OpenSearch
query_opensearch() {
    local endpoint="$1"
    local query="$2"
    
    # Find the running opensearch container
    local container_id=$(docker ps --filter "name=$CONTAINER_PREFIX" --format "{{.ID}}" | head -n1)
    
    if [[ -z "$container_id" ]]; then
        echo "ERROR: OpenSearch container not found"
        return 1
    fi
    
    if [[ -n "$query" ]]; then
        docker exec "$container_id" curl -s -X POST "$OPENSEARCH_URL/$endpoint" \
            -H "Content-Type: application/json" \
            -d "$query"
    else
        docker exec "$container_id" curl -s "$OPENSEARCH_URL/$endpoint"
    fi
}

# Function to get workflow execution statistics
get_execution_stats() {
    local timestamp=$(get_timestamp)
    log "=== Workflow Execution Statistics ($timestamp) ==="
    
    # Get total execution count
    local total_executions=$(query_opensearch "workflowexecution-*/_count" "" | jq -r '.count // 0')
    log "Total executions: $total_executions"
    
    # Get executions by status
    local status_query='{
        "size": 0,
        "aggs": {
            "status_counts": {
                "terms": {
                    "field": "status.keyword",
                    "size": 20
                }
            }
        }
    }'
    
    local status_stats=$(query_opensearch "workflowexecution-*/_search" "$status_query")
    echo "$status_stats" | jq -r '.aggregations.status_counts.buckets[] | "\(.key): \(.doc_count)"' | while read line; do
        log "  Status $line"
    done
    
    # Get recent executions (last 10 minutes)
    local recent_query='{
        "query": {
            "range": {
                "started_at": {
                    "gte": "now-10m"
                }
            }
        },
        "size": 0
    }'
    
    local recent_count=$(query_opensearch "workflowexecution-*/_count" "$recent_query" | jq -r '.count // 0')
    log "Recent executions (last 10min): $recent_count"
    
    # Save to stats file
    local stats_file="$STATS_DIR/execution_stats_$timestamp.json"
    echo "{
        \"timestamp\": \"$(date -Iseconds)\",
        \"total_executions\": $total_executions,
        \"recent_executions\": $recent_count,
        \"status_breakdown\": $(echo "$status_stats" | jq '.aggregations.status_counts.buckets // []')
    }" > "$stats_file"
}

# Function to get operation counts by workflow
get_operation_stats() {
    local timestamp=$(get_timestamp)
    log "=== Operation Statistics by Workflow ($timestamp) ==="
    
    # Query for executions with operation details
    local ops_query='{
        "size": 1000,
        "query": {
            "range": {
                "started_at": {
                    "gte": "now-1h"
                }
            }
        },
        "_source": ["workflow_id", "status", "results", "execution_argument", "started_at", "completed_at"]
    }'
    
    local ops_data=$(query_opensearch "workflowexecution-*/_search" "$ops_query")
    
    # Process and analyze the operations
    echo "$ops_data" | jq -r '.hits.hits[] | {
        workflow_id: ._source.workflow_id,
        status: ._source.status,
        started_at: ._source.started_at,
        completed_at: ._source.completed_at,
        result_count: (._source.results | length // 0)
    }' | while read -r execution; do
        if [[ -n "$execution" ]]; then
            local workflow_id=$(echo "$execution" | jq -r '.workflow_id // "unknown"')
            local status=$(echo "$execution" | jq -r '.status // "unknown"')
            local result_count=$(echo "$execution" | jq -r '.result_count // 0')
            
            log "  Workflow $workflow_id: status=$status, operations=$result_count"
        fi
    done
    
    # Save detailed operation stats
    local ops_file="$STATS_DIR/operation_stats_$timestamp.json"
    echo "$ops_data" > "$ops_file"
}

# Function to detect stuck operations
detect_stuck_operations() {
    local timestamp=$(get_timestamp)
    log "=== Detecting Stuck Operations ($timestamp) ==="
    
    # Look for executions that have been running for more than 5 minutes
    local stuck_query='{
        "query": {
            "bool": {
                "must": [
                    {
                        "terms": {
                            "status.keyword": ["EXECUTING", "WAITING", "RUNNING"]
                        }
                    },
                    {
                        "range": {
                            "started_at": {
                                "lte": "now-5m"
                            }
                        }
                    }
                ]
            }
        },
        "sort": [
            {
                "started_at": {
                    "order": "asc"
                }
            }
        ],
        "_source": ["workflow_id", "execution_id", "status", "started_at", "results"]
    }'
    
    local stuck_executions=$(query_opensearch "workflowexecution-*/_search" "$stuck_query")
    local stuck_count=$(echo "$stuck_executions" | jq -r '.hits.total.value // 0')
    
    if [[ "$stuck_count" -gt 0 ]]; then
        log "WARNING: Found $stuck_count potentially stuck executions!"
        
        echo "$stuck_executions" | jq -r '.hits.hits[] | {
            workflow_id: ._source.workflow_id,
            execution_id: ._source.execution_id,
            status: ._source.status,
            started_at: ._source.started_at,
            operations_count: (._source.results | length // 0)
        }' | while read -r stuck; do
            if [[ -n "$stuck" ]]; then
                local workflow_id=$(echo "$stuck" | jq -r '.workflow_id // "unknown"')
                local execution_id=$(echo "$stuck" | jq -r '.execution_id // "unknown"')
                local status=$(echo "$stuck" | jq -r '.status // "unknown"')
                local started_at=$(echo "$stuck" | jq -r '.started_at // "unknown"')
                local ops_count=$(echo "$stuck" | jq -r '.operations_count // 0')
                
                log "  STUCK: Workflow $workflow_id, Execution $execution_id"
                log "    Status: $status, Started: $started_at, Operations: $ops_count"
            fi
        done
        
        # Save stuck operations for further analysis
        local stuck_file="$STATS_DIR/stuck_operations_$timestamp.json"
        echo "$stuck_executions" > "$stuck_file"
    else
        log "No stuck operations detected"
    fi
}

# Function to monitor Docker container resources
monitor_container_resources() {
    local timestamp=$(get_timestamp)
    log "=== Container Resource Usage ($timestamp) ==="
    
    # Get stats for all shuffle containers
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | grep shuffle | while read line; do
        log "  $line"
    done
    
    # Save container stats
    local container_file="$STATS_DIR/container_stats_$timestamp.json"
    docker stats --no-stream --format '{"container":"{{.Container}}","cpu":"{{.CPUPerc}}","memory":"{{.MemUsage}}","network":"{{.NetIO}}","timestamp":"'$(date -Iseconds)'"}' | grep shuffle > "$container_file"
}

# Function to generate summary report
generate_summary() {
    local timestamp=$(get_timestamp)
    log "=== Summary Report ($timestamp) ==="
    
    # Count files in stats directory
    local stats_files=$(ls -1 "$STATS_DIR" | wc -l)
    log "Statistics files collected: $stats_files"
    
    # Show latest stats directory size
    local stats_size=$(du -sh "$STATS_DIR" 2>/dev/null | cut -f1 || echo "unknown")
    log "Statistics directory size: $stats_size"
    
    # Show log file size
    local log_size=$(du -sh "$LOG_FILE" 2>/dev/null | cut -f1 || echo "unknown")
    log "Log file size: $log_size"
    
    log "=== Monitor cycle complete ==="
    echo
}

# Main monitoring loop
main() {
    log "Starting Shuffle Operations Monitor"
    log "Monitoring interval: ${INTERVAL}s"
    log "OpenSearch URL: $OPENSEARCH_URL"
    log "Stats directory: $STATS_DIR"
    
    # Handle cleanup on exit
    trap 'log "Monitor stopped"; exit 0' INT TERM
    
    while true; do
        # Run all monitoring functions
        get_execution_stats
        get_operation_stats
        detect_stuck_operations
        monitor_container_resources
        generate_summary
        
        # Wait for next cycle
        sleep "$INTERVAL"
    done
}

# Show usage if called with --help
if [[ "${1:-}" == "--help" ]]; then
    echo "Shuffle Operations Monitor"
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --help        Show this help message"
    echo "  --once        Run monitoring cycle once and exit"
    echo "  --interval N  Set monitoring interval (default: ${INTERVAL}s)"
    echo ""
    echo "Environment variables:"
    echo "  OPENSEARCH_URL    OpenSearch URL (default: $OPENSEARCH_URL)"
    echo "  STATS_DIR         Statistics directory (default: $STATS_DIR)"
    echo "  LOG_FILE          Log file path (default: $LOG_FILE)"
    exit 0
fi

# Handle --once option
if [[ "${1:-}" == "--once" ]]; then
    log "Running single monitoring cycle"
    get_execution_stats
    get_operation_stats
    detect_stuck_operations
    monitor_container_resources
    generate_summary
    exit 0
fi

# Handle --interval option
if [[ "${1:-}" == "--interval" ]] && [[ -n "${2:-}" ]]; then
    INTERVAL="$2"
    shift 2
fi

# Run main function
main "$@"