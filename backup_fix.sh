#!/bin/bash

# --- Configuration ---
CACHE_DIR="/home/.duplicity"
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
LOG_FILE="/var/log/backup.log"

# Colors for easier reading
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${YELLOW}--- Starting Backup Diagnostics & Remediation ---${NC}"

# ==============================================================================
# STEP 1: Cache Cleanup with Path Verification
# ==============================================================================
echo -e "\n${YELLOW}[Step 1] Verifying and Cleaning Duplicity Cache...${NC}"

if [ -d "$CACHE_DIR" ]; then
    cd "$CACHE_DIR" || { echo -e "${RED}Failed to CD into $CACHE_DIR. Exiting.${NC}"; exit 1; }
    
    CURRENT_PATH=$(pwd)
    
    if [[ "$CURRENT_PATH" == "$CACHE_DIR" ]]; then
        echo -e "${GREEN}Path confirmed: $CURRENT_PATH${NC}"
        echo "Clearing dub cache..."
        rm -rf ./*
        echo -e "${GREEN}Cache cleared successfully.${NC}"
    else
        echo -e "${RED}CRITICAL: Current path ($CURRENT_PATH) does not match target ($CACHE_DIR). Aborting delete.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Directory $CACHE_DIR does not exist. Skipping cleanup.${NC}"
fi

# ==============================================================================
# STEP 2: Display Raw Content
# ==============================================================================
echo -e "\n${YELLOW}[Step 2] Reading Configuration Files${NC}"
echo "----------------------------------------------------"

echo -e "${CYAN}--- Content of $FACTS_FILE ---${NC}"
if [ -f "$FACTS_FILE" ]; then
    cat "$FACTS_FILE"
else
    echo -e "${RED}File $FACTS_FILE not found!${NC}"
fi

echo -e "\n${CYAN}--- Content of $LOG_FILE ---${NC}"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
    LOG_CONTENT=$(cat "$LOG_FILE")
else
    echo -e "${RED}File $LOG_FILE not found!${NC}"
    LOG_CONTENT=""
fi

# ==============================================================================
# STEP 3: Smart Analysis (Status & Errors)
# ==============================================================================
echo -e "\n${YELLOW}[Step 3] Analyzing Errors & Status${NC}"

# 1. Detect App Name
DB_NAME=$(grep -oE "last_backup_[a-z0-9]+" "$FACTS_FILE" | head -n 1 | sed 's/last_backup_//')

if [ -z "$DB_NAME" ]; then
    # Fallback: Try to find pattern in log if not in facts
    DB_NAME=$(echo "$LOG_CONTENT" | grep -oE "\b[a-z0-9]{10,}\b" | head -n 1)
fi

echo -e "Detected App/DB Name: ${CYAN}$DB_NAME${NC}"

# 2. Check Specific Status in Facts File
if [ ! -z "$DB_NAME" ] && [ -f "$FACTS_FILE" ]; then
    # Extract the exact line for this DB
    STATUS_LINE=$(grep "last_backup_$DB_NAME" "$FACTS_FILE")
    echo -e "Facts Status: $STATUS_LINE"

    # Check if the status line looks like a timestamp (Success) or an Error
    # Assuming success looks like "DD/MM/YYYY..." or just a date string. 
    # If it contains "Error", "Failed", or "Exit", we flag it.
    if echo "$STATUS_LINE" | grep -iqE "error|failed|exit|code"; then
        echo -e "${RED}>> Error Code detected in Facts file.${NC}"
    else
        echo -e "${GREEN}>> Facts file shows valid timestamp (No explicit error code in facts).${NC}"
        echo "   Proceeding to check Logs for deeper issues..."
    fi
fi

# 3. Analyze Logs SPECIFICALLY for this App/DB
# We filter log lines to matches containing the DB_NAME to avoid false positives from other apps.
APP_LOGS=$(echo "$LOG_CONTENT" | grep "$DB_NAME")

# If no specific logs found for app, check recent general errors
if [ -z "$APP_LOGS" ]; then
    echo "No specific log entries found for $DB_NAME. Checking general log tail..."
    APP_LOGS=$(tail -n 20 "$LOG_FILE")
fi

# --- Check for Storage Issues ---
if echo "$APP_LOGS" | grep -iqE "storage|disk|space|write error"; then
    echo -e "\n${RED}>>> STORAGE ISSUE DETECTED FOR $DB_NAME <<<${NC}"
    
    echo -e "Checking Disk Usage:"
    df -h
    
    if [ ! -z "$DB_NAME" ]; then
        echo -e "Checking App Size:"
        sudo apm -s "$DB_NAME" -d
    fi
fi

# --- Check for Resource Issues (Dump Failed / Memory) ---
RESTART_REQUIRED=false

if echo "$APP_LOGS" | grep -iqE "dump failed|memory|oom|swap|timeout"; then
    echo -e "\n${RED}>>> DUMP FAILED / RESOURCE ISSUE DETECTED FOR $DB_NAME <<<${NC}"
    RESTART_REQUIRED=true
    
    echo -e "Checking Resources:"
    echo -n "Memory: " && free -m | grep "Mem:" | awk '{print $3"/"$2 " MB used"}'
    echo -n "Swap:   " && free -m | grep "Swap:" | awk '{print $3"/"$2 " MB used"}'
    echo -n "Load:   " && uptime | awk -F'load average:' '{ print $2 }'
else
    echo -e "\n${GREEN}No critical dump/memory errors found in logs for this specific app.${NC}"
fi

# ==============================================================================
# STEP 4: Remediation
# ==============================================================================

if [ "$RESTART_REQUIRED" = true ]; then
    echo -e "\n${YELLOW}[Step 4] Executing Remediation (Clear Swap & Restart Services)${NC}"
    
    echo "Clearing Swap..."
    sudo swapoff -a && sudo swapon -a
    
    echo "Restarting Services..."
    
    restart_service() {
        if systemctl list-unit-files | grep -q "$1.service"; then
            echo " -> Restarting $1..."
            sudo systemctl restart "$1"
        fi
    }

    restart_service "apache2"
    restart_service "nginx"
    
    # Auto-detect PHP version
    PHP_SERVICE=$(systemctl list-units --type=service | grep -o "php.*-fpm.service" | head -n 1)
    [ ! -z "$PHP_SERVICE" ] && restart_service "$PHP_SERVICE"

    restart_service "mysql"

    echo -e "${GREEN}Remediation complete.${NC}"
else
    echo -e "\n${GREEN}Diagnostics finished. No remediation actions required.${NC}"
fi
