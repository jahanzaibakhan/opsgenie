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
    
    # Only remove files inside the folder
    rm -rf ./* 2>/dev/null
    echo -e "${GREEN}✅ Duplicity cache cleared.${NC}"
    
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
echo -e "\n${BOLD}🗂️ Step 3: Detecting failed apps from facts file${NC}"
FACT_FILE="/etc/ansible/facts.d/backup.fact"
DISK_ERROR_FOUND=false
ERROR_APPS=()

if [ -f "$FACT_FILE" ]; then
    while IFS= read -r line; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}🔴 $line${NC}"
            APP_NAME=$(echo "$line" | awk -F'=' '{print $1}' | sed 's/error_code_//')
            ERROR_APPS+=("$APP_NAME")
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
# Step 6: Show Failed Apps DB/File Sizes
# ===============================
echo -e "\n${BOLD}📦 Step 6: Failed Apps DB & File Sizes${NC}"

APPS_PATH="/home/master/applications"
declare -A APP_TOTAL_BYTES

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

printf "${BOLD}%-20s %-15s %-15s %-15s${NC}\n" "App Name" "File Size" "DB Size" "Total Size"
printf "%-20s %-15s %-15s %-15s\n" "--------" "---------" "--------" "----------"

for APP in "${ERROR_APPS[@]}"; do
    APP_PATH_FULL="$APPS_PATH/$APP"

    if [[ -d "$APP_PATH_FULL" ]]; then
        FILE_SIZE=$(du -sh "$APP_PATH_FULL" 2>/dev/null | awk '{print $1}')
        FILE_BYTES=$(to_bytes "$FILE_SIZE")
    else
        FILE_SIZE="N/A"
        FILE_BYTES=0
    fi

    DB_PATH="/var/lib/mysql/$APP"
    if [[ -d "$DB_PATH" ]]; then
        DB_SIZE=$(du -sh "$DB_PATH" 2>/dev/null | awk '{print $1}')
        DB_BYTES=$(to_bytes "$DB_SIZE")
    else
        DB_SIZE="0"
        DB_BYTES=0
    fi

    TOTAL_BYTES=$(( FILE_BYTES + DB_BYTES ))
    TOTAL_SIZE=$(to_readable "$TOTAL_BYTES")

    APP_TOTAL_BYTES["$APP"]=$TOTAL_BYTES

    printf "${RED}%-20s${NC} %-15s %-15s %-15s\n" "$APP" "$FILE_SIZE" "$DB_SIZE" "$TOTAL_SIZE"
done

# ===============================
# Step 7: Report Remarks
# ===============================
echo -e "\n${BOLD}📝 Step 7: Report Remarks${NC}"
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
