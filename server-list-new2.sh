#!/bin/bash

printf "%-15s %-12s %-12s\n" "Server IP" "Disk(%)" "Inode(%)"
printf "%-15s %-12s %-12s\n" "---------" "--------" "---------"

for SERVER in "$@"; do

    DISK=$(cng $SERVER <<EOF 2>/dev/null | tail -1 | awk '{print $5}'
df -h /
exit
EOF
)

    INODE=$(cng $SERVER <<EOF 2>/dev/null | tail -1 | awk '{print $5}'
df -i /
exit
EOF
)

    printf "%-15s %-12s %-12s\n" "$SERVER" "${DISK:-N/A}" "${INODE:-N/A}"

done
