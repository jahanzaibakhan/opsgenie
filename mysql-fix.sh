#!/bin/bash

# mysql-fix.sh - Adjust MariaDB OOM Score to prevent OOM killer from targeting it
# Usage: sudo bash mysql-fix.sh

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e "${CYAN}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[DONE]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Step 1: Ensure running as root ---
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Use: sudo bash mysql-fix.sh"
fi

echo ""
echo "============================================"
echo "   MariaDB OOM Score Fix - mysql-fix.sh"
echo "============================================"
echo ""

# --- Step 2: Create drop-in directory ---
DIR="/etc/systemd/system/mariadb.service.d"
log "Checking for systemd drop-in directory: $DIR"

if [[ ! -d "$DIR" ]]; then
    log "Directory not found. Creating $DIR ..."
    mkdir -p "$DIR"
    ok "Directory created: $DIR"
else
    ok "Directory already exists: $DIR"
fi

echo ""

# --- Step 3: Create the config file ---
CONF_FILE="$DIR/oom-score.conf"
log "Creating config file: $CONF_FILE"

cat > "$CONF_FILE" <<EOF
[Service]
OOMScoreAdjust=-800
EOF

ok "File created: $CONF_FILE"
log "Rule applied: OOMScoreAdjust=-800 (MariaDB is now protected from OOM killer)"

echo ""

# --- Step 4: Reload systemd daemon ---
log "Reloading systemd daemon (daemon-reload) ..."
systemctl daemon-reload
ok "Systemd daemon reloaded successfully."

echo ""

# --- Step 5: Restart MariaDB ---
log "Restarting MariaDB service ..."
systemctl restart mariadb
ok "MariaDB restarted successfully."

echo ""

# --- Step 6: Verify ---
log "Verifying MariaDB service status ..."
STATUS=$(systemctl is-active mariadb 2>/dev/null)

if [[ "$STATUS" == "active" ]]; then
    ok "MariaDB is running (status: active)."
else
    error "MariaDB failed to start. Status: $STATUS. Run 'systemctl status mariadb' for details."
fi

echo ""
echo "============================================"
echo -e "${GREEN}   All steps completed successfully!${NC}"
echo "============================================"
echo ""
echo "  Config: $CONF_FILE"
echo "  Rule  : OOMScoreAdjust=-800"
echo "  MySQL : Running"
echo ""
