#!/bin/bash

# ===============================
# Color codes
# ===============================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}====================================${NC}"
echo -e "${BOLD}🔍 Backup Issue Checker Script Start${NC}"
echo -e "${BOLD}====================================${NC}\n"

# ===============================
# Step 1: Verify and Clear Duplicity Cache
# ===============================
DUPLICITY_CACHE="/home/.duplicity"
echo -e "${BOLD}🧹 Step 1: Clearing duplicity cache at $DUPLICITY_CACHE...${NC}"

if [ -d "$DUPLICITY_CACHE" ]; then
    CURRENT_PATH=$(pwd)
    cd "$DUPLICITY_CACHE" || { echo -e "${RED}❌ Cannot cd to $DUPLICITY_CACHE${NC}"; exit 1; }
    echo -e "${GREEN}✔ Path confirmed: $(pwd)${NC}"
    
    # Only remove files inside the folder, not the folder itself
    rm -rf ./* 2>/dev/null
    echo -e "${GREEN}✅ Duplicity cache cleared.${NC}"
    
    # Return to original path
    cd "$CURRENT_PATH"
else
    echo -e "${RED}⚠️ Duplicity cache directory not found.${NC}"
fi

# ===============================
# Step 2: Show CPU load and memory usage
# ===============================
echo -e "\n${BOLD}📊 Step 2: System Resource Usage${NC}"
echo "--------------------------"
echo -e "🖥️  CPU Load Average:"
uptime | awk -F'load average:' '{ print "   "$2 }'

echo -e "\n🧠 Memory Usage:"
free -h

echo -e "\n🔥 Top 5 CPU-consuming processes:"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

# ===============================
# Step 3: Show and highlight errors from backup.fact
# ===============================
echo -e "\n${BOLD}🗂️ Step 3: Highlighting errors from backup facts${NC}"
FACT_FILE="/etc/ansible/facts.d/backup.fact"
DISK_ERROR_FOUND=false

if [ -f "$FACT_FILE" ]; then
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}🔴 $line${NC}"
            if echo "$line" | grep -qiE "disk|storage"; then
                DISK_ERROR_FOUND=true
            fi
        else
            echo "$line"
        fi
    done < "$FACT_FILE"
else
    echo -e "${RED}❌ File not found: $FACT_FILE${NC}"
fi

# ===============================
# Step 4: Check and highlight errors from backup.log
# ===============================
echo -e "\n${BOLD}📄 Step 4: Checking backup.log for errors${NC}"
LOG_FILE="/var/log/backup.log"
if [ -f "$LOG_FILE" ]; then
    FOUND_ERRORS=false
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}🔴 $line${NC}"
            FOUND_ERRORS=true
            if echo "$line" | grep -qiE "disk|storage"; then
                DISK_ERROR_FOUND=true
            fi
        fi
    done < "$LOG_FILE"

    if [ "$FOUND_ERRORS" = false ]; then
        echo -e "${GREEN}✅ No error lines found in backup.log.${NC}"
    fi
else
    echo -e "${RED}❌ File not found: $LOG_FILE${NC}"
fi

# ===============================
# Step 5: Show Disk Usage
# ===============================
echo -e "\n${BOLD}💾 Step 5: Disk Usage${NC}"
df -h

# ===============================
# Step 6: Report Remarks
# ===============================
echo -e "\n${BOLD}📝 Step 6: Report Remarks${NC}"
if [ "$DISK_ERROR_FOUND" = true ]; then
    echo -e "${RED}${BOLD}⚠️ Disk/storage related errors found.${NC}"
    echo -e "🔹 Check backup.fact and backup.log for details."
    echo -e "🔹 Current server storage (df -h):"
    df -h
else
    echo -e "${GREEN}✅ No disk/storage related errors detected.${NC}"
fi

echo -e "\n${BOLD}====================================${NC}"
echo -e "${GREEN}${BOLD}✔ Backup Issue Checker Completed${NC}"
echo -e "${BOLD}====================================${NC}"
