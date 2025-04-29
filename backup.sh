#!/bin/bash

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "===================================="
echo "🔍 Backup Issue Checker Script Start"
echo "===================================="
echo

# Step 1: Clear duplicity cache
DUPLICITY_CACHE="/home/.duplicity/"
echo "🧹 Clearing duplicity cache at $DUPLICITY_CACHE..."

if [ -d "$DUPLICITY_CACHE" ]; then
    rm -rf "${DUPLICITY_CACHE:?}"/*
    echo -e "${GREEN}✅ Duplicity cache cleared.${NC}"
else
    echo -e "${RED}⚠️ Duplicity cache directory not found.${NC}"
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

# Step 3: Show and highlight errors from backup.fact
echo
echo "🗂️ Showing /etc/ansible/facts.d/backup.fact contents..."
FACT_FILE="/etc/ansible/facts.d/backup.fact"
if [ -f "$FACT_FILE" ]; then
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}🔴 $line${NC}"
        else
            echo "$line"
        fi
    done < "$FACT_FILE"
else
    echo -e "${RED}❌ File not found: $FACT_FILE${NC}"
fi

# Step 4: Check and highlight errors from backup log
echo
echo "📄 Checking /var/log/backup.log for errors..."
LOG_FILE="/var/log/backup.log"
if [ -f "$LOG_FILE" ]; then
    FOUND_ERRORS=false
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}🔴 $line${NC}"
            FOUND_ERRORS=true
        fi
    done < "$LOG_FILE"

    if [ "$FOUND_ERRORS" = false ]; then
        echo -e "${GREEN}✅ No error lines found in backup.log.${NC}"
    fi
else
    echo -e "${RED}❌ File not found: $LOG_FILE${NC}"
fi

# Final Summary
echo
echo "===================================="
echo "✅ Backup Check Completed - Summary:"
echo "===================================="
echo "✔ Duplicity cache cleaned (if found)"
echo "✔ System CPU and RAM usage reported"
echo "✔ Displayed backup.fact with error highlighting"
echo "✔ Checked backup.log with error highlighting"
echo "===================================="
