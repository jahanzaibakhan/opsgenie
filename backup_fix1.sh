#!/bin/bash

# --- Configuration ---
CACHE_DIR="/home/.duplicity"
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
LOG_FILE="/var/log/backup.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}--- Starting Backup Diagnostics ---${NC}"

# ==============================================================================
# STEP 1: Cache Cleanup (Safe)
# ==============================================================================
echo -e "\n${YELLOW}[Step 1] Verifying and Cleaning Duplicity Cache...${NC}"

if [ -d "$CACHE_DIR" ]; then
    cd "$CACHE_DIR" || exit 1
    if [[ "$(pwd)" == "$CACHE_DIR" ]]; then
        echo -e "${GREEN}Path confirmed: $(pwd)${NC}"
        rm -rf ./*
        echo -e "${GREEN}Cache cleared.${NC}"
    else
        echo -e "${RED}Path Mismatch. Aborting delete.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Directory $CACHE_DIR not found.${NC}"
fi

# ==============================================================================
# STEP 2: Show Current Status
# ==============================================================================
echo -e "\n${YELLOW}[Step 2] Reading Files${NC}"
echo "----------------------------------------------------"

echo -e "${CYAN}--- Facts File ---${NC}"
[ -f "$FACTS_FILE" ] && cat "$FACTS_FILE" || echo "Facts file not found."

echo -e "\n${CYAN}--- Log File ---${NC}"
[ -f "$LOG_FILE" ] && cat "$LOG_FILE" || echo "Log file not found."

# Load content for analysis
FACTS_CONTENT=$(cat "$FACTS_FILE" 2>/dev/null)
LOG_CONTENT=$(cat "$LOG_FILE" 2>/dev/null)

# ==============================================================================
# STEP 3: Smart Error Detection
# ==============================================================================
echo -e "\n${YELLOW}[Step 3] Analyzing for Errors${NC}"

TARGET_DB=""
ISSUE_FOUND=false

# 1. Check FACTS file for lines that DO NOT look like a valid date (DD/MM/YYYY)
# If a line has "last_backup_xyz =" but NO date, it's likely an error code.
FAILING_LINE=$(grep "last_backup_" "$FACTS_FILE" | grep -vE "[0-9]{2}/[0-9]{2}/[0-9]{4}" | head -n 1)

if [ ! -z "$FAILING_LINE" ]; then
    echo -e "${RED}>> Error Detected in Facts File:${NC} $FAILING_LINE"
    TARGET_DB=$(echo "$FAILING_LINE" | grep -oE "last_backup_[a-z0-9]+" | sed 's/last_backup_//')
    ISSUE_FOUND=true
fi

# 2. If no facts error, check LOGS for specific keywords associated with a DB
if [ "$ISSUE_FOUND" = false ]; then
    if echo "$LOG_CONTENT" | grep -iqE "dump failed|storage|write error"; then
        # Find the DB name mentioned near the error in the logs
        # Extracts string matching 10+ alphanumeric chars
        POTENTIAL_DB=$(echo "$LOG_CONTENT" | grep -oE "\b[a-z0-9]{10,}\b" | head -n 1)
        
        if [ ! -z "$POTENTIAL_DB" ]; then
             TARGET_DB="$POTENTIAL_DB"
             echo -e "${RED}>> Error Detected in Logs for DB:${NC} $TARGET_DB"
             ISSUE_FOUND=true
        fi
    fi
fi

# ==============================================================================
# STEP 4: Conditional Diagnostics & Remediation
# ==============================================================================

if [ "$ISSUE_FOUND" = true ] && [ ! -z "$TARGET_DB" ]; then
    echo -e "\n${YELLOW}[Step 4] Running Diagnostics for $TARGET_DB${NC}"

    # -- Storage Check --
    # Check if the logs specifically mention storage/disk
    if echo "$LOG_CONTENT" | grep -iqE "storage|disk|space"; then
        echo -e "${RED}Possible Storage Issue.${NC}"
        df -h
        echo "Checking App Size:"
        sudo apm -s "$TARGET_DB" -d
    fi

    # -- Resource Check (Memory/Dump) --
    if echo "$LOG_CONTENT" | grep -iqE "dump failed|memory|oom|swap"; then
        echo -e "${RED}Dump Failed / Resource Issue Detected.${NC}"
        
        echo "--- Resource Status ---"
        free -m
        uptime
        
        echo -e "\n${YELLOW}[Step 5] Executing Remediation${NC}"
        echo "Clearing Swap..."
        sudo swapoff -a && sudo swapon -a
        
        echo "Restarting Services..."
        sudo systemctl restart apache2
        sudo systemctl restart nginx
        sudo systemctl restart mysql
        
        # PHP Dynamic Restart
        PHP_SVC=$(systemctl list-units --type=service | grep -o "php.*-fpm.service" | head -n 1)
        [ ! -z "$PHP_SVC" ] && sudo systemctl restart "$PHP_SVC"
        
        echo -e "${GREEN}Remediation Done.${NC}"
    fi

else
    # HAPPY PATH: No errors found
    echo -e "\n${GREEN}>> System Healthy: No failed backups or errors detected.${NC}"
    echo "Skipping diagnostics and remediation."
fi
