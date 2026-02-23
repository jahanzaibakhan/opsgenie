#!/bin/bash

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 ServerIP1 ServerIP2 ..."
    exit 1
fi

printf "%-15s %-12s %-12s\n" "Server IP" "Disk(%)" "Inode(%)"
printf "%-15s %-12s %-12s\n" "---------" "--------" "---------"

for SERVER in "$@"; do

    DISK=$(cng $SERVER 2>/dev/null <<EOF | awk 'NR==2 {print $5}'
df -h /
exit
EOF
)

    INODE=$(cng $SERVER 2>/dev/null <<EOF | awk 'NR==2 {print $5}'
df -i /
exit
EOF
)

    if [[ "$DISK" =~ % ]] && [[ "$INODE" =~ % ]]; then
        printf "%-15s %-12s %-12s\n" "$SERVER" "$DISK" "$INODE"
    else
        printf "%-15s %-12s %-12s\n" "$SERVER" "Failed" "Failed"
    fi

done
