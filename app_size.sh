#!/bin/bash

APPS_PATH="/home/master/applications"

# Convert human-readable size to BYTES (integer only)
to_bytes() {
    local size="$1"
    local num unit bytes

    num=$(echo "$size" | sed -E 's/([0-9.]+).*/\1/')
    unit=$(echo "$size" | sed -E 's/[0-9.]+(.*)/\1/' | tr '[:lower:]' '[:upper:]')

    case "$unit" in
        B|"")   bytes=$(printf "%.0f" "$num") ;;
        K|KB)   bytes=$(printf "%.0f" "$(echo "$num * 1024" | bc)") ;;
        M|MB)   bytes=$(printf "%.0f" "$(echo "$num * 1024 * 1024" | bc)") ;;
        G|GB)   bytes=$(printf "%.0f" "$(echo "$num * 1024 * 1024 * 1024" | bc)") ;;
        T|TB)   bytes=$(printf "%.0f" "$(echo "$num * 1024 * 1024 * 1024 * 1024" | bc)") ;;
        *)      bytes=0 ;;
    esac

    echo "$bytes"
}

# Convert bytes → M/G readable format
to_readable() {
    local bytes=$1
    if (( bytes >= 1024*1024*1024 )); then
        echo "$(echo "scale=2; $bytes/1024/1024/1024" | bc)G"
    elif (( bytes >= 1024*1024 )); then
        echo "$(echo "scale=2; $bytes/1024/1024" | bc)M"
    else
        echo "${bytes}B"
    fi
}

# Table header
printf "%-20s %-15s %-15s %-15s\n" "DB Name" "File Size" "DB Size" "Total Size"
printf "%-20s %-15s %-15s %-15s\n" "-------" "---------" "--------" "----------"

# Loop apps
for APP in $(ls -1 $APPS_PATH); do
    APP_PATH="$APPS_PATH/$APP"

    # Skip if not a directory or if symlink
    if [[ ! -d "$APP_PATH" || -L "$APP_PATH" ]]; then
        continue
    fi

    DB_NAME="$APP"

    # FILE SIZE
    FILE_SIZE=$(du -sh "$APP_PATH" 2>/dev/null | awk '{print $1}')
    FILE_BYTES=$(to_bytes "$FILE_SIZE")

    # DB SIZE
    DB_SIZE=$(sudo apm -s "$DB_NAME" -d 2>/dev/null | grep "Size" | awk '{print $2}')
    if [[ -z "$DB_SIZE" ]]; then
        DB_SIZE="0"
        DB_BYTES=0
    else
        DB_BYTES=$(to_bytes "$DB_SIZE")
    fi

    # SAFE INTEGER TOTAL WITHOUT DECIMAL
    TOTAL_BYTES=$(( FILE_BYTES + DB_BYTES ))
    TOTAL_SIZE=$(to_readable "$TOTAL_BYTES")

    printf "%-20s %-15s %-15s %-15s\n" "$DB_NAME" "$FILE_SIZE" "$DB_SIZE" "$TOTAL_SIZE"
done
