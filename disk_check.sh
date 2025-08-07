#!/bin/bash

# Variables
APP_DIR="/home/master/applications"
DB_DIR="/var/lib/mysql"
LOG_FILE="/var/cw/system/size.log"
NOW=$(date '+%Y-%m-%d %H:%M:%S')

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Function to show loading animation
loading_msg() {
    local msg="$1"
    echo -n "$msg"
    for i in {1..3}; do
        echo -n "."
        sleep 0.3
    done
    echo ""
}

# Start log + terminal output
{
    echo ""
    echo "========== DISK USAGE REPORT - $NOW =========="
    echo ""

    loading_msg "Calculating individual application folder sizes"
    echo "---- Application Folder Sizes ----"

    total_size_bytes=0

    for folder in "$APP_DIR"/*/; do
        if [ -d "$folder" ]; then
            size_human=$(du -sh "$folder" 2>/dev/null | cut -f1)
            size_bytes=$(du -sb "$folder" 2>/dev/null | cut -f1)
            folder_name=$(basename "$folder")
            total_size_bytes=$((total_size_bytes + size_bytes))
            echo "$folder_name - $size_human"
        fi
    done

    echo ""
    loading_msg "Calculating total size of all apps"
    total_app_size_human=$(awk "BEGIN {printf \"%.1fG\", $total_size_bytes/1024/1024/1024}")
    echo "📦 App File Size (Total): $total_app_size_human"

    echo ""
    loading_msg "Calculating total database size"
    db_size=$(du -sh "$DB_DIR" 2>/dev/null | cut -f1)
    echo "🗃️ All Database Size (MySQL): $db_size"

    echo ""
    loading_msg "Finding top 15 largest directories on the server"
    echo "---- TOP 15 Largest Directories on the Server ----"
    du -ahx / 2>/dev/null | sort -rh | head -n 15

    echo ""
    echo "========== END OF REPORT =========="
    echo ""
    echo "💾 You can view the full log at: $LOG_FILE"
    echo ""
} | tee -a "$LOG_FILE"
