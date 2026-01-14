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
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
BACKUP_SCRIPT="/var/cw/scripts/bash/duplicity_backup.sh"

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup & Disk Recovery Script${NC}"
echo -e "${BOLD} Executed at: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}==================================================${NC}"

# ===============================
# STEP 1: SHOW DISK USAGE
# ===============================
echo
echo -e "${BOLD}▶ Step 1: Disk Usage${NC}"
df -h

# ===============================
# STEP 2: READ FACTS FILE & DETECT ERROR APPS
# ===============================
echo
echo -e "${BOLD}▶ Step 2: Detecting failed apps from facts file${NC}"

if [[ ! -f "$FACTS_FILE" ]]; then
    echo -e "${RED}❌ Facts file not found: $FACTS_FILE${NC}"
    exit 1
fi

ERROR_APPS=()
declare -A ERROR_CODES

while IFS='=' read -r KEY VALUE; do
    if [[ "$KEY" =~ ^error_code_ ]]; then
        APP_NAME="${KEY#error_code_}"
        if [[ "$VALUE" -ne 0 ]]; then
            ERROR_APPS+=("$APP_NAME")
            ERROR_CODES["$APP_NAME"]="$VALUE"
            echo -e "${RED}${BOLD}⚠️ App $APP_NAME failed with error_code=$VALUE${NC}"
        fi
    fi
done < "$FACTS_FILE"

if [[ ${#ERROR_APPS[@]} -eq 0 ]]; then
    echo -e "${GREEN}✅ No failed apps detected in facts file${NC}"
    exit 0
fi

# ===============================
# STEP 3: SHOW DB & FILE SIZE TABLE FOR FAILED APPS
# ===============================
echo
echo -e "${BOLD}▶ Step 3: DB & File Sizes for Failed Apps${NC}"

APPS_PATH="/home/master/applications"

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

# Table header
printf "${BOLD}%-20s %-15s %-15s %-15s${NC}\n" "App Name" "File Size" "DB Size" "Total Size"
printf "%-20s %-15s %-15s %-15s\n" "--------" "---------" "--------" "----------"

for APP in "${ERROR_APPS[@]}"; do
    APP_PATH="$APPS_PATH/$APP"

    # Skip if app folder missing
    if [[ ! -d "$APP_PATH" ]]; then
        FILE_SIZE="N/A"
        FILE_BYTES=0
    else
        FILE_SIZE=$(du -sh "$APP_PATH" 2>/dev/null | awk '{print $1}')
        FILE_BYTES=$(to_bytes "$FILE_SIZE")
    fi

    # DB size
    DB_PATH="/var/lib/mysql/$APP"
    if [[ -d "$DB_PATH" ]]; then
        DB_SIZE=$(du -sh "$DB_PATH" 2>/dev/null | awk '{print $1}')
        DB_BYTES=$(to_bytes "$DB_SIZE")
    else
        DB_SIZE="0"
        DB_BYTES=0
    fi

    # Total
    TOTAL_BYTES=$(( FILE_BYTES + DB_BYTES ))
    TOTAL_SIZE=$(to_readable "$TOTAL_BYTES")

    # Print table row
    printf "${RED}%-20s${NC} %-15s %-15s %-15s\n" "$APP" "$FILE_SIZE" "$DB_SIZE" "$TOTAL_SIZE"
done

# ===============================
# STEP 4: CHECK CPU USAGE
# ===============================
echo
echo -e "${BOLD}▶ Step 4: Checking CPU Usage${NC}"

CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d. -f1)
CPU_USAGE=$((100 - CPU_IDLE))
echo -e "${YELLOW}CPU Usage: $CPU_USAGE%${NC}"

if [[ "$CPU_USAGE" -gt 70 ]]; then
    echo -e "${RED}${BOLD}⚠️ CPU is above 70%, restarting services...${NC}"
    echo -e "${YELLOW}Stopping apache2, nginx, php-fpm, mysql...${NC}"
    sudo systemctl restart apache2 nginx php-fpm mysql
    echo -e "${GREEN}✅ Services restarted successfully${NC}"
else
    echo -e "${GREEN}✅ CPU usage is normal${NC}"
fi

# ===============================
# STEP 5: CHECK SWAP USAGE
# ===============================
echo
echo -e "${BOLD}▶ Step 5: Checking SWAP Memory${NC}"
SWAP_USED=$(free -m | awk 'NR==3{print $3}')
SWAP_TOTAL=$(free -m | awk 'NR==3{print $2}')
SWAP_PERCENT=$((SWAP_USED*100/SWAP_TOTAL))
echo -e "Swap usage: $SWAP_USED/$SWAP_TOTAL MB ($SWAP_PERCENT%)"

if [[ "$SWAP_PERCENT" -gt 50 ]]; then
    echo -e "${RED}${BOLD}⚠️ Swap memory above 50%, clearing swap...${NC}"
    sudo swapoff -a && sudo swapon -a
    echo -e "${GREEN}✅ Swap memory cleared${NC}"
else
    echo -e "${GREEN}✅ Swap memory usage is normal${NC}"
fi

# ===============================
# STEP 6: INTERACTIVE BACKUP PROMPT (SKIP EMPTY APPS)
# ===============================
echo
echo -e "${BOLD}▶ Step 6: Backup failed apps interactively${NC}"

for APP in "${ERROR_APPS[@]}"; do
    # Skip apps with total size 0 or missing
    TOTAL_BYTES=$(( ${FILE_BYTES:-0} + ${DB_BYTES:-0} ))
    if [[ "$TOTAL_BYTES" -eq 0 ]]; then
        echo -e "${YELLOW}⚠️ Skipping backup prompt for $APP (File+DB size = 0)${NC}"
        continue
    fi

    while true; do
        read -rp "$(echo -e "Do you want to take backup for ${BOLD}$APP${NC}? [Y/N]: ")" ANSWER </dev/tty
        ANSWER=$(echo "$ANSWER" | tr '[:upper:]' '[:lower:]')
        if [[ "$ANSWER" == "y" ]]; then
            echo -e "${YELLOW}▶ Running backup for $APP...${NC}"
            sudo "$BACKUP_SCRIPT" -a "$APP"
            echo -e "${GREEN}✅ Backup completed for $APP${NC}"
            break
        elif [[ "$ANSWER" == "n" ]]; then
            echo -e "${YELLOW}⚠️ Skipped backup for $APP${NC}"
            break
        else
            echo -e "${RED}❌ Invalid input. Please enter Y or N.${NC}"
        fi
    done
done

# ===============================
# STEP 7: SHOW NEW BACKUP STATUS FROM FACTS FILE
# ===============================
echo
echo -e "${BOLD}▶ Step 7: New backup status from facts file${NC}"

for APP in "${ERROR_APPS[@]}"; do
    LAST_BACKUP=$(grep "last_backup_$APP" "$FACTS_FILE" | awk -F'= ' '{print $2}')
    if [[ -n "$LAST_BACKUP" ]]; then
        echo -e "${GREEN}App $APP last backup: $LAST_BACKUP${NC}"
    else
        echo -e "${RED}App $APP last backup info not found${NC}"
    fi
done

echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${GREEN}${BOLD}✔ Script execution completed successfully${NC}"
echo -e "${BOLD}==================================================${NC}"
