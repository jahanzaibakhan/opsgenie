#!/bin/bash

# ===============================
# ANSI COLOR CODES
# ===============================
RED='\033[1;31m'      # Bold Red
GREEN='\033[1;32m'    # Bold Green
YELLOW='\033[1;33m'   # Bold Yellow
BOLD='\033[1m'
NC='\033[0m'          # No Color

# ===============================
# CONFIGURATION
# ===============================
DUPLICITY_PATH="/home/.duplicity"
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
BACKUP_LOG="/var/log/backup.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup Error Detection & Storage Diagnosis Script${NC}"
echo -e "${BOLD} Executed at: $DATE${NC}"
echo -e "${BOLD}==================================================${NC}"

# ===============================
# STEP 0: VERIFY PATH & CLEAR DUPLICITY CACHE
# ===============================
echo
echo -e "${BOLD}▶ Step 0: Verifying duplicity cache path${NC}"

cd "$DUPLICITY_PATH" 2>/dev/null || {
    echo -e "${RED}❌ Failed to cd into $DUPLICITY_PATH${NC}"
    exit 1
}

CURRENT_PATH=$(pwd)
echo "Current path: $CURRENT_PATH"

if [[ "$CURRENT_PATH" != "$DUPLICITY_PATH" ]]; then
    echo -e "${RED}❌ PATH VERIFICATION FAILED — ABORTING${NC}"
    exit 1
fi

echo -e "${GREEN}✅ PATH CONFIRMED${NC}"
echo -e "${YELLOW}🧹 Clearing duplicity cache (files only)${NC}"

find "$DUPLICITY_PATH" -type f -exec rm -f {} \;

echo -e "${GREEN}✅ Duplicity cache cleared safely${NC}"

# ===============================
# STEP 1: SHOW DISK USAGE (ALWAYS)
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 1: Disk Usage (df -h)${NC}"
echo -e "${BOLD}==================================================${NC}"
df -h

# ===============================
# STEP 2: READ BACKUP FACTS FILE
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 2: Backup Facts File${NC}"
echo -e "${BOLD}==================================================${NC}"

if [[ -f "$FACTS_FILE" ]]; then
    cat "$FACTS_FILE"
else
    echo -e "${RED}❌ Facts file not found: $FACTS_FILE${NC}"
    exit 1
fi

# ===============================
# STEP 3: DETECT ERRORS FROM FACTS
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 3: Detecting Application Errors${NC}"
echo -e "${BOLD}==================================================${NC}"

ERROR_APPS=()
DISK_ERROR_APPS=()

while IFS='=' read -r KEY VALUE; do
    if [[ "$KEY" =~ ^error_code_ ]]; then
        APP_NAME="${KEY#error_code_}"
        ERROR_APPS+=("$APP_NAME")

        if [[ "$VALUE" == "40" ]]; then
            DISK_ERROR_APPS+=("$APP_NAME")
            echo -e "${RED}${BOLD}⚠️ Disk-related error: $APP_NAME (error_code=$VALUE)${NC}"
        else
            echo -e "${RED}⚠️ Error detected: $APP_NAME (error_code=$VALUE)${NC}"
        fi
    fi
done < <(grep "^error_code_" "$FACTS_FILE")

if [[ ${#ERROR_APPS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No application errors found in facts file${NC}"
fi

# ===============================
# STEP 4: BACKUP LOG OUTPUT
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 4: Backup Log Output${NC}"
echo -e "${BOLD}==================================================${NC}"

if [[ -f "$BACKUP_LOG" ]]; then
    cat "$BACKUP_LOG"
else
    echo -e "${RED}❌ Backup log not found: $BACKUP_LOG${NC}"
fi

# ===============================
# STEP 5: ANALYZE BACKUP LOG
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 5: Backup Log Analysis${NC}"
echo -e "${BOLD}==================================================${NC}"

LOG_DISK_ERROR=false
LOG_DUMP_ERROR=false

if grep -Ei "no space|disk full|storage" "$BACKUP_LOG" >/dev/null; then
    LOG_DISK_ERROR=true
    echo -e "${RED}${BOLD}⚠️ Storage-related error detected in backup log${NC}"
fi

if grep -Ei "dump failed|mysqldump" "$BACKUP_LOG" >/dev/null; then
    LOG_DUMP_ERROR=true
    echo -e "${RED}${BOLD}⚠️ Database dump failure detected in backup log${NC}"
fi

if [[ "$LOG_DISK_ERROR" == false && "$LOG_DUMP_ERROR" == false ]]; then
    echo -e "${GREEN}✅ No critical storage or dump errors found in backup log${NC}"
fi

# ===============================
# STEP 6: APP SIZE SCAN (DISK ERRORS ONLY)
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 6: Application Size Scan${NC}"
echo -e "${BOLD}==================================================${NC}"

if [[ ${#DISK_ERROR_APPS[@]} -gt 0 || "$LOG_DISK_ERROR" == true ]]; then
    echo -e "${YELLOW}⚠️ Disk-related issues found — scanning app sizes${NC}"

    for APP in "${DISK_ERROR_APPS[@]}"; do
        echo
        echo -e "${BOLD}▶ App: $APP${NC}"
        sudo apm -s "$APP" -d
    done
else
    echo -e "${GREEN}✅ No disk-related app errors — skipping size scan${NC}"
fi

# ===============================
# STEP 7: CPU / MEMORY / SWAP (DUMP FAIL)
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 7: CPU, Memory & Swap Check${NC}"
echo -e "${BOLD}==================================================${NC}"

if [[ "$LOG_DUMP_ERROR" == true ]]; then
    echo -e "${YELLOW}▶ CPU usage snapshot${NC}"
    top -b -n1 | head -15

    echo
    echo -e "${YELLOW}▶ Memory usage${NC}"
    free -m

    echo
    echo -e "${YELLOW}▶ Swap usage${NC}"
    swapon --show
else
    echo -e "${GREEN}✅ No dump-related issues — skipping CPU/memory checks${NC}"
fi

# ===============================
# STEP 8: FINAL DISK AVAILABILITY
# ===============================
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}▶ Step 8: Final Disk Availability Summary${NC}"
echo -e "${BOLD}==================================================${NC}"

echo -e "${BOLD}Filesystem\tSize\tUsed\tAvail\tUse%\tMounted on${NC}"
df -h | awk 'NR==1 || $NF ~ /^\/$/ || $NF ~ /^\/home$/ {print}'

echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD}✔ Script execution completed successfully${NC}"
echo -e "${BOLD}==================================================${NC}"
