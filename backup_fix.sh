#!/bin/bash

# --- Configuration ---
# CORRECTED PATH:
CACHE_DIR="/home/.duplicity"
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
LOG_FILE="/var/log/backup.log"

# Colors for easier reading
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}--- Starting Backup Diagnostics & Remediation ---${NC}"

# ==============================================================================
# STEP 1: Cache Cleanup with Path Verification
# ==============================================================================
echo -e "\n${YELLOW}[Step 1] Verifying and Cleaning Duplicity Cache...${NC}"

if [ -d "$CACHE_DIR" ]; then
    # CD into the folder
    cd "$CACHE_DIR" || { echo -e "${RED}Failed to CD into $CACHE_DIR. Exiting.${NC}"; exit 1; }
    
    # Get current path to verify
    CURRENT_PATH=$(pwd)
    
    # Verify we are exactly where we expect to be
    if [[ "$CURRENT_PATH" == "$CACHE_DIR" ]]; then
        echo -e "${GREEN}Path confirmed: $CURRENT_PATH${NC}"
        echo "Clearing dub cache..."
        
        # Safe remove: Removing content inside the folder, not the folder itself
        rm -rf ./*
        
        if [ $? -eq 0 ]; then
             echo -e "${GREEN}Cache cleared successfully.${NC}"
        else
             echo -e "${RED}Error clearing cache.${NC}"
        fi
    else
        echo -e "${RED}CRITICAL: Current path ($CURRENT_PATH) does not match target ($CACHE_DIR). Aborting delete.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Directory $CACHE_DIR does not exist. Skipping cleanup.${NC}"
fi

# ==============================================================================
# STEP 2: Display Logs and Status
# ==============================================================================
echo -e "\n${YELLOW}[Step 2] Backup Status (Facts File)${NC}"
echo "----------------------------------------------------"
if [ -f "$FACTS_FILE" ]; then
    cat "$FACTS_FILE"
else
    echo -e "${RED}File $FACTS_FILE not found!${NC}"
fi

echo -e "\n${YELLOW}[Step 3] Backup Error Logs${NC}"
echo "----------------------------------------------------"
if [ -f "$LOG_FILE" ]; then
    cat "$LOG_FILE"
    
    # Store log content in variable for analysis
    LOG_CONTENT=$(cat "$LOG_FILE")
else
    echo -e "${RED}File $LOG_FILE not found!${NC}"
    LOG_CONTENT=""
fi

# ==============================================================================
# STEP 3: Log Analysis & Resource Checks
# ==============================================================================
echo -e "\n${YELLOW}[Step 4] Analyzing Errors...${NC}"

# Try to extract the DB Name (looking for pattern like 'last_backup_hvqcgdqrhn' in facts file)
# We grep for 'last_backup_' followed by alphanumeric chars, take the first result, and strip the prefix.
DB_NAME=$(grep -oE "last_backup_[a-z0-9]+" "$FACTS_FILE" | head -n 1 | sed 's/last_backup_//')

# Fallback: If not found in facts, try to find a similar string in the log file
if [ -z "$DB_NAME" ]; then
    DB_NAME=$(echo "$LOG_CONTENT" | grep -oE "\b[a-z0-9]{10,}\b" | head -n 1)
fi

echo "Detected App/DB Name: $DB_NAME"

# --- Check for Storage Related Errors ---
# Keywords: storage, disk, space, write error
if echo "$LOG_CONTENT" | grep -iqE "storage|disk|space|write error"; then
    echo -e "${RED}>>> STORAGE ISSUE DETECTED <<<${NC}"
    
    echo -e "\nChecking General Disk Usage:"
    df -h
    
    if [ ! -z "$DB_NAME" ]; then
        echo -e "\nChecking Specific App Size for: $DB_NAME"
        # Using the specific command requested
        sudo apm -s "$DB_NAME" -d
    else
        echo -e "${YELLOW}Could not identify specific DB name to run 'apm -s'.${NC}"
    fi
fi

# --- Check for Dump / Memory / CPU Related Errors ---
RESTART_REQUIRED=false

# Keywords: dump failed, memory, oom, swap, timeout
if echo "$LOG_CONTENT" | grep -iqE "dump failed|memory|oom|swap|timeout"; then
    echo -e "${RED}>>> DUMP FAILURE / RESOURCE ISSUE DETECTED <<<${NC}"
    RESTART_REQUIRED=true
    
    echo -e "\n--- CPU & Memory Status ---"
    echo "Memory (MB):"
    free -m
    echo ""
    echo "CPU Load:"
    uptime
    echo ""
    echo "Swap Status:"
    swapon --show
    
    # Also check storage here because large DB dumps can fail if /tmp is full
    echo -e "\nChecking Disk (Temp space check):"
    df -h /
fi

# ==============================================================================
# STEP 4: Remediation (Clearing Memory & Restarting Services)
# ==============================================================================

if [ "$RESTART_REQUIRED" = true ]; then
    echo -e "\n${YELLOW}[Step 5] Executing Remediation (Clear Swap & Restart Services)${NC}"
    echo "Authorized to clear memory and reboot Apache2, Nginx, PHP-FPM, MySQL."
    
    # 1. Clear Swap (Swapoff then Swapon) to free up accumulated swap usage
    echo "Clearing Swap..."
    sudo swapoff -a && sudo swapon -a
    echo -e "${GREEN}Swap cleared.${NC}"
    
    # 2. Restart Services
    echo "Restarting Services..."
    
    # Helper function to restart service only if it exists
    restart_service() {
        # Check if service unit file exists
        if systemctl list-unit-files | grep -q "$1.service"; then
            echo "Restarting $1..."
            sudo systemctl restart "$1"
        else
            echo "Service $1 not found, skipping."
        fi
    }

    restart_service "apache2"
    restart_service "nginx"
    
    # Restart PHP-FPM (Wildcard restart to catch version like php8.1-fpm or php7.4-fpm)
    # Finding the running php-fpm service name
    PHP_SERVICE=$(systemctl list-units --type=service | grep -o "php.*-fpm.service" | head -n 1)
    if [ ! -z "$PHP_SERVICE" ]; then
        echo "Restarting PHP Service: $PHP_SERVICE"
        sudo systemctl restart "$PHP_SERVICE"
    else
        echo "PHP-FPM service not found."
    fi

    restart_service "mysql" # Works for MariaDB usually as well due to alias

    echo -e "${GREEN}Remediation complete. Please re-run backup manually to test.${NC}"
else
    echo -e "\n${GREEN}No critical dump/memory errors detected requiring service restarts.${NC}"
fi

echo -e "\n${YELLOW}--- Diagnostics Complete ---${NC}"
