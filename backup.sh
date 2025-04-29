#!/bin/bash

echo "=== Backup Issue Checker Script ==="
echo

# Step 1: Clear duplicity cache
echo "Clearing duplicity cache..."
DUPLICITY_CACHE="/home/.duplicity/"
if [ -d "$DUPLICITY_CACHE" ]; then
    rm -rf ${DUPLICITY_CACHE:?}/*
    echo "✅ Duplicity cache cleared."
else
    echo "❌ Duplicity cache directory not found!"
fi

# Step 2: Check CPU load, memory, and RAM
echo
echo "=== System Resource Usage ==="
echo "CPU Load Average:"
uptime | awk -F'load average:' '{ print $2 }'

echo
echo "Memory Usage:"
free -h

echo
echo "Top 5 CPU Consuming Processes:"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

# Step 3: Check backup facts for errors
echo
echo "=== Checking /etc/ansible/facts.d/backup.fact for errors ==="
if [ -f /etc/ansible/facts.d/backup.fact ]; then
    grep -i "error" /etc/ansible/facts.d/backup.fact || echo "No error lines found."
else
    echo "❌ File not found: /etc/ansible/facts.d/backup.fact"
fi

# Step 4: Check backup log for errors
echo
echo "=== Checking /var/log/backup.log for errors ==="
if [ -f /var/log/backup.log ]; then
    grep -i "error" /var/log/backup.log || echo "No error lines found."
else
    echo "❌ File not found: /var/log/backup.log"
fi

# Final summary
echo
echo "=== Summary ==="
echo "✔ Duplicity cache cleared (if it existed)"
echo "✔ System load, CPU, and memory checked"
echo "✔ Checked /etc/ansible/facts.d/backup.fact for errors"
echo "✔ Checked /var/log/backup.log for errors"
echo
echo "✅ Backup check script completed."
