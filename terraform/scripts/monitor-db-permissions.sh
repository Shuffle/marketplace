#!/bin/bash

# Monitor and fix permissions for /opt/shuffle/shuffle-database directory
# This script runs perpetually checking every 5 seconds until the directory
# exists with correct permissions (owned by 1000:1000)

SHUFFLE_DB_DIR="/opt/shuffle/shuffle-database"
TARGET_UID=1000
TARGET_GID=1000
CHECK_INTERVAL=5

echo "[$(date)] Starting shuffle-database permissions monitor..."

while true; do
    if [ -d "$SHUFFLE_DB_DIR" ]; then
        # Get current ownership
        CURRENT_UID=$(stat -c %u "$SHUFFLE_DB_DIR" 2>/dev/null)
        CURRENT_GID=$(stat -c %g "$SHUFFLE_DB_DIR" 2>/dev/null)
        
        if [ "$CURRENT_UID" = "$TARGET_UID" ] && [ "$CURRENT_GID" = "$TARGET_GID" ]; then
            echo "[$(date)] Directory $SHUFFLE_DB_DIR exists with correct permissions (1000:1000). Exiting."
            exit 0
        else
            echo "[$(date)] Fixing permissions for $SHUFFLE_DB_DIR (current: $CURRENT_UID:$CURRENT_GID, target: $TARGET_UID:$TARGET_GID)"
            sudo chown 1000:1000 -R "$SHUFFLE_DB_DIR"
            
            # Verify the change
            NEW_UID=$(stat -c %u "$SHUFFLE_DB_DIR" 2>/dev/null)
            NEW_GID=$(stat -c %g "$SHUFFLE_DB_DIR" 2>/dev/null)
            
            if [ "$NEW_UID" = "$TARGET_UID" ] && [ "$NEW_GID" = "$TARGET_GID" ]; then
                echo "[$(date)] Permissions successfully updated to 1000:1000. Exiting."
                exit 0
            else
                echo "[$(date)] Warning: Failed to update permissions. Will retry in $CHECK_INTERVAL seconds."
            fi
        fi
    else
        echo "[$(date)] Directory $SHUFFLE_DB_DIR does not exist yet. Checking again in $CHECK_INTERVAL seconds..."
    fi
    
    sleep $CHECK_INTERVAL
done