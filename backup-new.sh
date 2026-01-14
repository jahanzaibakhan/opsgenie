#!/bin/bash

# ===============================
# Color & formatting
# ===============================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ===============================
# Header
# ===============================
echo -e "${BOLD}====================================${NC}"
echo -e "${BOLD}🔍 Backup Issue Checker Script Start${NC}"
echo -e "${BOLD}====================================${NC}\n"

# ===============================
# Step 1: Verify & clear duplicity cache
# ===============================
DUPLICITY_CACHE="/home/.duplicity"

echo -e "${BOLD}🧹 Step 1: Clearing duplicity cache${NC}"

if [[ -d "$DUPLICITY_CACHE" ]]; then
    cd "$DUPLICITY_CACHE" || {
        echo -e "${RED}❌ Failed to cd into $DUPLICITY_CACHE${NC}"
        exit 1
    }

    echo -e "${GREEN}✔ Path verified: $(pwd)${NC}"
    rm -rf ./* 2>/dev/null
    echo -e "${GREEN}✅ Duplicity cache cleared${NC}"
else
    echo -e "${YELLOW}⚠️ Duplicity cache directory not found${NC}"
fi

# ===============================
# Step 2: CPU & memory overview
# ===============================
echo -e "\n${BOLD}📊 Step 2: System Resource Usage${NC}"
echo "--------------------------"

echo -e "🖥️ CPU Load Average:"
uptime | awk -F'load average:' '{print "   "$2}'

echo -e "\n🧠 Memory Usage:"
free -h

echo -e "\n🔥 Top CPU-consuming processes:"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

# ===============================
# Step 3: Parse backup.fact for errors
# ===============================
echo -e "\n${BOLD}🗂️ Step 3: Detecting failed apps from facts file${NC}"

FACT_FILE="/etc/ansible/facts.d/backup.fact"
ERROR_APPS=()
DISK_ERROR_FOUND=false

if [[ -f "$FACT_FILE" ]]; then
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error_code_"; then
            echo -e "${RED}🔴 $line${NC}"
            APP=$(echo "$line" | awk -F'=' '{print $1}' | sed 's/error_code_//')
            [[ -n "$APP" ]] && ERROR_APPS+=("$APP")
        else
            echo "$line"
        fi
    done < "$FACT_FILE"
else
    echo -e "${RED}❌ backup.fact not found${NC}"
fi

# ===============================
# Step 4: Show FULL backup.log + detect disk issues
# ===============================
echo -e "\n${BOLD}📄 Step 4: Full backup.log output${NC}"

LOG_FILE="/var/log/backup.log"

if [[ -f "$LOG_FILE" ]]; then
    echo "--------------------------------------------------"
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}$line${NC}"

            # Detect temp space issue
            if [[ "$line" =~ Temp\ space\ has\ ([0-9]+)\ available,\ backup\ needs\ approx\ ([0-9]+) ]]; then
                AVAIL=${BASH_REMATCH[1]}
                NEED=${BASH_REMATCH[2]}
                (( AVAIL < NEED )) && DISK_ERROR_FOUND=true
            fi
        else
            echo "$line"
        fi
    done < "$LOG_FILE"
    echo "--------------------------------------------------"
else
    echo -e "${RED}❌ backup.log not found${NC}"
fi

# ===============================
# Step 5: Disk usage & critical FS detection
# ===============================
echo -e "\n${BOLD}💾 Step 5: Disk Usage${NC}"
df -h

while read -r FS SIZE USED AVAIL USEP MOUNT; do
    [[ "$USEP" == *"%"* ]] || continue
    USE=${USEP%\%}
    if (( USE >= 90 )); then
        echo -e "${RED}${BOLD}⚠️ Filesystem $FS mounted on $MOUNT is critically full (${USEP})${NC}"
        DISK_ERROR_FOUND=true
    fi
done < <(df -h --output=source,size,used,avail,pcent,target | tail -n +2)

# ===============================
# Step 6: Failed apps DB & file sizes
# ===============================
echo -e "\n${BOLD}📦 Step 6: Failed Apps DB & File Sizes${NC}"

APPS_PATH="/home/master/applications"

to_bytes() {
    echo "$1" | awk '
    /G/ {print $1*1024*1024*1024}
    /M/ {print $1*1024*1024}
    /K/ {print $1*1024}
    /B/ {print $1}
    '
}

to_readable() {
    local b=$1
    (( b >= 1073741824 )) && echo "$(bc <<<"scale=2;$b/1073741824")G" && return
    (( b >= 1048576 )) && echo "$(bc <<<"scale=2;$b/1048576")M" && return
    echo "${b}B"
}

printf "${BOLD}%-20s %-15s %-15s %-15s${NC}\n" "App Name" "File Size" "DB Size" "Total Size"
printf "%-20s %-15s %-15s %-15s\n" "--------" "---------" "--------" "----------"

for APP in "${ERROR_APPS[@]}"; do
    FILE_SIZE="N/A"
    FILE_BYTES=0
    DB_SIZE="0"
    DB_BYTES=0

    [[ -d "$APPS_PATH/$APP" ]] && FILE_SIZE=$(du -sh "$APPS_PATH/$APP" 2>/dev/null | awk '{print $1}')
    [[ -n "$FILE_SIZE" && "$FILE_SIZE" != "N/A" ]] && FILE_BYTES=$(to_bytes "$FILE_SIZE")

    [[ -d "/var/lib/mysql/$APP" ]] && DB_SIZE=$(du -sh "/var/lib/mysql/$APP" 2>/dev/null | awk '{print $1}')
    [[ -n "$DB_SIZE" && "$DB_SIZE" != "0" ]] && DB_BYTES=$(to_bytes "$DB_SIZE")

    TOTAL_BYTES=$((FILE_BYTES + DB_BYTES))
    TOTAL_SIZE=$(to_readable "$TOTAL_BYTES")

    printf "${RED}%-20s${NC} %-15s %-15s %-15s\n" "$APP" "$FILE_SIZE" "$DB_SIZE" "$TOTAL_SIZE"
done

# ===============================
# Step 7: Final report remarks
# ===============================
echo -e "\n${BOLD}📝 Step 7: Report Remarks${NC}"

if [[ "$DISK_ERROR_FOUND" == true ]]; then
    echo -e "${RED}${BOLD}⚠️ Disk/storage related errors found.${NC}"
    echo -e "🔹 Backup log shows insufficient temp/disk space"
    echo -e "🔹 One or more filesystems are critically full"
    echo -e "🔹 App sizes above correlate with disk exhaustion"
else
    echo -e "${GREEN}✅ No disk/storage related errors detected${NC}"
fi

echo -e "\n${BOLD}====================================${NC}"
echo -e "${GREEN}${BOLD}✔ Backup Issue Checker Completed${NC}"
echo -e "${BOLD}====================================${NC}"
