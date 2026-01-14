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
# STEP 3: SHOW DB & FILE SIZE TABLE FOR EACH FAILED APP (FIXED)
# ===============================
echo
echo -e "${BOLD}▶ Step 3: DB & File Sizes for Failed Apps${NC}"

printf "${BOLD}%-20s %-20s %-20s${NC}\n" "App Name" "DB Size" "Files Size"
printf "%-20s %-20s %-20s\n" "--------" "-------" "----------"

declare -A APP_SIZES

for APP in "${ERROR_APPS[@]}"; do
    echo -e "${BOLD}App: $APP${NC}"
    
    # Run the apm command
    RAW_OUTPUT=$(sudo apm -s "$APP" -d)
    
    # Print raw output for debugging
    echo "$RAW_OUTPUT"
    
    # Extract DB and Files size more flexibly
    DB_SIZE=$(echo "$RAW_OUTPUT" | grep -iE "DB Size|Database Size" | awk -F: '{print $2}' | xargs)
    FILE_SIZE=$(echo "$RAW_OUTPUT" | grep -iE "Files Size|Files" | awk -F: '{print $2}' | xargs)
    
    # If not found, show N/A
    [[ -z "$DB_SIZE" ]] && DB_SIZE="N/A"
    [[ -z "$FILE_SIZE" ]] && FILE_SIZE="N/A"
    
    APP_SIZES["$APP"]="DB: $DB_SIZE | Files: $FILE_SIZE"
    printf "${RED}%-20s${NC} %-20s %-20s\n" "$APP" "$DB_SIZE" "$FILE_SIZE"
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
# STEP 6: INTERACTIVE BACKUP PROMPT (FIXED)
# ===============================
echo
echo -e "${BOLD}▶ Step 6: Backup failed apps interactively${NC}"

for APP in "${ERROR_APPS[@]}"; do
    while true; do
        # Use /dev/tty to force interactive input
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
