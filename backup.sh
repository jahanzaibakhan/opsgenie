#!/bin/bash

echo "===================================="
echo "🔍 Backup Issue Checker Script Start"
echo "===================================="
echo

# Step 1: Clear duplicity cache
DUPLICITY_CACHE="/home/.duplicity/"
echo "🧹 Clearing duplicity cache at $DUPLICITY_CACHE..."

if [ -d "$DUPLICITY_CACHE" ]; then
    rm -rf "${DUPLICITY_CACHE:?}"/*
    echo "✅ Duplicity cache cleared."
else
    echo "⚠️ Duplicity cache directory not found."
fi

# Step 2: Show CPU load and memory usage
echo
echo "📊 System Resource Usage:"
echo "--------------------------"
echo "🖥️  CPU Load Average:"
uptime | awk -F'load average:' '{ print $2 }' | sed 's/^/   /'

echo
echo "🧠 Memory Usage:"
free -h

echo
echo "🔥 Top 5 CPU-consuming processes:"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

# Step 3: Check backup facts for errors
echo
echo "🗂️ Checking /etc/ansible/facts.d/backup.fact for errors..."
if [ -f /etc/ansible/facts.d/backup.fact ]; then
    grep -i "error" /etc/ansible/facts.d/backup.fact || echo "✅ No error lines found in backup.fact."
else
    echo "❌ File not found: /etc/ansible/facts.d/backup.fact"
fi

# Step 4: Check backup log for errors
echo
echo "🗂️ Checking /var/log/backup.log for errors..."
if [ -f /var/log/backup.log ]; then
    grep -i "error" /var/log/backup.log || echo "✅ No error lines found in backup.log."
else
    echo "❌ File not found: /var/log/backup.log"
fi

# Final Summary
echo
echo "===================================="
echo "✅ Backup Check Completed - Summary:"
echo "===================================="
echo "✔ Duplicity cache cleaned (if found)"
echo "✔ System CPU and RAM usage reported"
echo "✔ Checked backup.fact for errors"
echo "✔ Checked backup.log for errors"
echo "===================================="
