#!/bin/bash

printf "%-15s %-12s %-12s\n" "Server IP" "Disk(%)" "Inode(%)"
printf "%-15s %-12s %-12s\n" "---------" "--------" "---------"

for SERVER in "$@"; do

    OUTPUT=$(cng $SERVER <<EOF 2>/dev/null
df -h /
df -i /
exit
EOF
)

    DISK=$(echo "$OUTPUT" | grep -Eo '[0-9]+%' | head -1)
    INODE=$(echo "$OUTPUT" | grep -Eo '[0-9]+%' | tail -1)

    printf "%-15s %-12s %-12s\n" "$SERVER" "${DISK:-N/A}" "${INODE:-N/A}"

done
