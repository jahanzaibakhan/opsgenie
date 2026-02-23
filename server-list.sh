#!/bin/bash

# Check if at least one server IP is provided
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 ServerIP1 ServerIP2 ..."
    exit 1
fi

printf "%-15s %-15s %-15s\n" "Server IP" "Disk Usage" "Inode Usage"
printf "%-15s %-15s %-15s\n" "---------" "----------" "------------"

for SERVER in "$@"; do

    # Get Disk usage of root partition
    DISK=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SERVER \
        "df -h / | awk 'NR==2 {print \$5}'" 2>/dev/null)

    # Get Inode usage of root partition
    INODE=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SERVER \
        "df -i / | awk 'NR==2 {print \$5}'" 2>/dev/null)

    # If SSH fails
    if [ -z "$DISK" ] || [ -z "$INODE" ]; then
        printf "%-15s %-15s %-15s\n" "$SERVER" "Connection Failed" "Connection Failed"
    else
        printf "%-15s %-15s %-15s\n" "$SERVER" "$DISK" "$INODE"
    fi

done
