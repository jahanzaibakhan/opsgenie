#!/bin/bash

# ===============================
# CONFIGURATION
# ===============================
DUPLICITY_PATH="/home/.duplicity"
FACTS_FILE="/etc/ansible/facts.d/backup.fact"
BACKUP_LOG="/var/log/backup.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "=================================================="
echo " Backup Error Detection & Storage Diagnosis Script"
echo " Executed at: $DATE"
echo "=================================================="

# ===============================
# STEP 0: VERIFY PATH & CLEAR DUPLICITY CACHE
# ===============================
echo
echo "▶ Step 0: Verifying duplicity cache path"

cd "$DUPLICITY_PATH" 2>/dev/null || {
    echo "❌ Failed to cd into $DUPLICITY_PATH"
    exit 1
}

CURRENT_PATH=$(pwd)
echo "Current path: $CURRENT_PATH"

if [[ "$CURRENT_PATH" != "$DUPLICITY_PATH" ]]; then
    echo "❌ PATH VERIFICATION FAILED — ABORTING"
    exit 1
fi

echo "✅ PATH CONFIRMED"
echo "🧹 Clearing duplicity cache (files only)"

# Safety: delete files only, never directory
find "$DUPLICITY_PATH" -type f -exec rm -f {} \;

echo "✅ Duplicity cache cleared safely"

# ===============================
# STEP 1: SHOW DISK USAGE (ALWAYS)
# ===============================
echo
echo "=================================================="
echo "▶ Step 1: Disk Usage (df -h)"
echo "=================================================="
df -h

# ===============================
# STEP 2: READ BACKUP FACTS FILE
# ===============================
echo
echo "=================================================="
echo "▶ Step 2: Backup Facts File"
echo "=================================================="

if [[ -f "$FACTS_FILE" ]]; then
    cat "$FACTS_FILE"
else
    echo "❌ Facts file not found: $FACTS_FILE"
    exit 1
fi

# ===============================
# STEP 3: DETECT ERRORS FROM FACTS
# ===============================
echo
echo "=================================================="
echo "▶ Step 3: Detecting Application Errors"
echo "=================================================="

ERROR_APPS=()
DISK_ERROR_APPS=()

while IFS='=' read -r KEY VALUE; do
    if [[ "$KEY" =~ ^error_code_ ]]; then
        APP_NAME="${KEY#error_code_}"
        ERROR_APPS+=("$APP_NAME")

        # error_code=40 → storage related
        if [[ "$VALUE" == "40" ]]; then
            DISK_ERROR_APPS+=("$APP_NAME")
        fi
    fi
done < <(grep "^error_code_" "$FACTS_FILE")

if [[ ${#ERROR_APPS[@]} -eq 0 ]]; then
    echo "✅ No application errors found in facts file"
else
    echo "⚠️ Errors detected for the following apps:"
    for APP in "${ERROR_APPS[@]}"; do
        echo " - $APP"
    done
fi

# ===============================
# STEP 4: BACKUP LOG OUTPUT
# ===============================
echo
echo "=================================================="
echo "▶ Step 4: Backup Log Output"
echo "=================================================="

if [[ -f "$BACKUP_LOG" ]]; then
    cat "$BACKUP_LOG"
else
    echo "❌ Backup log not found: $BACKUP_LOG"
fi

# ===============================
# STEP 5: ANALYZE BACKUP LOG
# ===============================
echo
echo "=================================================="
echo "▶ Step 5: Backup Log Analysis"
echo "=================================================="

LOG_DISK_ERROR=false
LOG_DUMP_ERROR=false

if grep -Ei "no space|disk full|storage" "$BACKUP_LOG" >/dev/null; then
    LOG_DISK_ERROR=true
    echo "⚠️ Storage-related error detected in backup log"
fi

if grep -Ei "dump failed|mysqldump" "$BACKUP_LOG" >/dev/null; then
    LOG_DUMP_ERROR=true
    echo "⚠️ Database dump failure detected in backup log"
fi

if [[ "$LOG_DISK_ERROR" == false && "$LOG_DUMP_ERROR" == false ]]; then
    echo "✅ No critical storage or dump errors found in backup log"
fi

# ===============================
# STEP 6: APP SIZE SCAN (DISK ERRORS ONLY)
# ===============================
echo
echo "=================================================="
echo "▶ Step 6: Application Size Scan"
echo "=================================================="

if [[ ${#DISK_ERROR_APPS[@]} -gt 0 || "$LOG_DISK_ERROR" == true ]]; then
    echo "⚠️ Disk-related issues found — scanning app sizes"

    for APP in "${DISK_ERROR_APPS[@]}"; do
        echo
        echo "▶ App: $APP"
        sudo apm -s "$APP" -d
    done
else
    echo "✅ No disk-related app errors — skipping size scan"
fi

# ===============================
# STEP 7: CPU / MEMORY / SWAP (DUMP FAIL)
# ===============================
echo
echo "=================================================="
echo "▶ Step 7: CPU, Memory & Swap Check"
echo "=================================================="

if [[ "$LOG_DUMP_ERROR" == true ]]; then
    echo "▶ CPU usage snapshot"
    top -b -n1 | head -15

    echo
    echo "▶ Memory usage"
    free -m

    echo
    echo "▶ Swap usage"
    swapon --show
else
    echo "✅ No dump-related issues — skipping CPU/memory checks"
fi

# ===============================
# STEP 8: FINAL DISK AVAILABILITY
# ===============================
echo
echo "=================================================="
echo "▶ Step 8: Final Disk Availability Summary"
echo "=================================================="

df -h | awk 'NR==1 || $NF ~ /^\/$/ || $NF ~ /^\/home$/'

echo
echo "=================================================="
echo "✔ Script execution completed successfully"
echo "=================================================="
