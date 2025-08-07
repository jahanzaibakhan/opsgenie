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
    declare -A seen_inodes

    for folder in "$APP_DIR"/*/; do
        if [ -d "$folder" ]; then
            inode=$(stat -c '%d:%i' "$folder")  # device:inode unique identifier
            if [[ -n "${seen_inodes[$inode]}" ]]; then
                continue  # Skip duplicate (already seen inode)
            fi
            seen_inodes[$inode]=1

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
    echo "App File Size (Total): $total_app_size_human"

    echo ""
    loading_msg "Calculating total database size"
    db_total_bytes=0
    echo "---- Database Sizes ----"
    for db_folder in "$DB_DIR"/*/; do
        if [ -d "$db_folder" ]; then
            db_size_human=$(du -sh "$db_folder" 2>/dev/null | cut -f1)
            db_size_bytes=$(du -sb "$db_folder" 2>/dev/null | cut -f1)
            db_name=$(basename "$db_folder")
            db_total_bytes=$((db_total_bytes + db_size_bytes))
            echo "$db_name - $db_size_human"
        fi
    done

    echo ""
    # Format DB size based on value
    if [ "$db_total_bytes" -ge $((1024 * 1024 * 1024)) ]; then
        db_total_human=$(awk "BEGIN {printf \"%.1fG\", $db_total_bytes/1024/1024/1024}")
    else
        db_total_human=$(awk "BEGIN {printf \"%.1fM\", $db_total_bytes/1024/1024}")
    fi

    echo "All Database Size (MySQL): $db_total_human"

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
