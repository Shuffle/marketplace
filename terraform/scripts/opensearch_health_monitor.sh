#!/bin/bash
# OpenSearch Health Monitor - tracks database responsiveness and queue status
set -euo pipefail

OPENSEARCH_URL="http://opensearch-circuit-breaker:9200"
LOG_FILE="/var/log/opensearch-health.log"
CHECK_INTERVAL=15  # seconds

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_opensearch_health() {
    local start_time=$(date +%s.%3N)
    
    # Test basic connectivity and response time
    if response=$(curl -s -m 10 "$OPENSEARCH_URL/_cluster/health" 2>/dev/null); then
        local end_time=$(date +%s.%3N)
        local response_time=$(echo "$end_time - $start_time" | bc -l)
        
        # Parse health status
        local status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "unknown")
        local active_shards=$(echo "$response" | jq -r '.active_shards' 2>/dev/null || echo "0")
        local pending_tasks=$(echo "$response" | jq -r '.number_of_pending_tasks' 2>/dev/null || echo "0")
        
        log "✅ Health: $status, Shards: $active_shards, Pending: $pending_tasks, Response: ${response_time}s"
        
        # Check if response time is concerning
        if (( $(echo "$response_time > 5.0" | bc -l) )); then
            log "⚠️  WARNING: Slow response time: ${response_time}s"
        fi
        
        # Check cluster status
        if [[ "$status" != "green" && "$status" != "yellow" ]]; then
            log "🔴 ALERT: Cluster status is $status"
            return 1
        fi
        
        return 0
    else
        log "🔴 CRITICAL: OpenSearch not responding"
        return 1
    fi
}

check_thread_pools() {
    # Check thread pool queue status
    if response=$(curl -s -m 5 "$OPENSEARCH_URL/_nodes/stats/thread_pool" 2>/dev/null); then
        # Extract key thread pool metrics
        local search_queue=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.search.queue // 0' 2>/dev/null || echo "0")
        local search_rejected=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.search.rejected // 0' 2>/dev/null || echo "0")
        local write_queue=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.write.queue // 0' 2>/dev/null || echo "0")
        local write_rejected=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.write.rejected // 0' 2>/dev/null || echo "0")
        local bulk_queue=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.bulk.queue // 0' 2>/dev/null || echo "0")
        local bulk_rejected=$(echo "$response" | jq -r '.nodes | to_entries[0].value.thread_pool.bulk.rejected // 0' 2>/dev/null || echo "0")
        
        log "📊 Queues - Search: $search_queue (rejected: $search_rejected), Write: $write_queue (rejected: $write_rejected), Bulk: $bulk_queue (rejected: $bulk_rejected)"
        
        # Alert on high queue sizes
        if [[ "$search_queue" -gt 5000 ]]; then
            log "⚠️  WARNING: High search queue: $search_queue"
        fi
        if [[ "$write_queue" -gt 500 ]]; then
            log "⚠️  WARNING: High write queue: $write_queue"
        fi
        
        # Alert on rejections
        if [[ "$search_rejected" -gt 0 || "$write_rejected" -gt 0 || "$bulk_rejected" -gt 0 ]]; then
            log "🔴 ALERT: Rejections detected - Search: $search_rejected, Write: $write_rejected, Bulk: $bulk_rejected"
        fi
        
        return 0
    else
        log "⚠️  Could not retrieve thread pool stats"
        return 1
    fi
}

check_memory_usage() {
    # Check JVM memory usage
    if response=$(curl -s -m 5 "$OPENSEARCH_URL/_nodes/stats/jvm" 2>/dev/null); then
        local heap_used_percent=$(echo "$response" | jq -r '.nodes | to_entries[0].value.jvm.mem.heap_used_percent // 0' 2>/dev/null || echo "0")
        local gc_time=$(echo "$response" | jq -r '.nodes | to_entries[0].value.jvm.gc.collectors.young.collection_time_in_millis // 0' 2>/dev/null || echo "0")
        
        log "💾 Memory - Heap: ${heap_used_percent}%, GC Time: ${gc_time}ms"
        
        # Alert on high memory usage
        if [[ "$heap_used_percent" -gt 85 ]]; then
            log "🔴 ALERT: High heap usage: ${heap_used_percent}%"
        fi
        
        return 0
    else
        log "⚠️  Could not retrieve memory stats"
        return 1
    fi
}

check_indices_health() {
    # Check index health and sizes
    if response=$(curl -s -m 5 "$OPENSEARCH_URL/_cat/indices?v&s=store.size:desc&h=index,health,docs.count,store.size" 2>/dev/null); then
        log "📑 Top Indices:"
        echo "$response" | head -5 | while read line; do
            if [[ "$line" != *"index"* ]]; then  # Skip header
                log "   $line"
            fi
        done
        return 0
    else
        log "⚠️  Could not retrieve index stats"
        return 1
    fi
}

main() {
    log "🚀 Starting OpenSearch Health Monitor"
    
    while true; do
        log "--- Health Check Cycle ---"
        
        # Basic health check
        if check_opensearch_health; then
            # If basic health is OK, do detailed checks
            check_thread_pools
            check_memory_usage
            check_indices_health
        else
            log "❌ Basic health check failed, skipping detailed checks"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

# Handle signals gracefully
trap 'log "OpenSearch health monitor shutting down"; exit 0' SIGTERM SIGINT

# Start monitoring
main