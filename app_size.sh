#!/bin/bash

# Define paths
APP_DIR="/home/master/applications"
LOG_FILE="/var/cw/system/size.log"

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Write and display header
{
    echo "Application Folder Sizes (Actual Disk Usage) - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "-----------------------------------------------------------------------"

    # Loop through top-level folders and get their actual disk usage
    for folder in "$APP_DIR"/*/; do
        if [ -d "$folder" ]; then
            size=$(du -sh "$folder" 2>/dev/null | cut -f1)
            echo "$folder - $size"
        fi
    done

    echo "-----------------------------------------------------------------------"
    echo "Completed logging folder sizes."
} | tee "$LOG_FILE"
