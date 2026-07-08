#!/bin/bash
# host-check.sh - Quick server health check
# Usage: curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh | bash -s <SERVER_IP>

SCRIPT_URL="https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh"
SERVER_IP="${1:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

# If an IP was given, check if it belongs to this machine.
# If not, SSH into the target and re-run the script there.
if [ -n "$1" ]; then
    LOCAL_IPS=$(hostname -I 2>/dev/null)
    if ! echo "$LOCAL_IPS" | grep -qw "$1"; then
        echo "Connecting to $1 via SSH..."
        ssh -o StrictHostKeyChecking=no \
            -o ConnectTimeout=10 \
            -o BatchMode=yes \
            "root@${1}" \
            "curl -s '${SCRIPT_URL}' | bash -s '${1}'"
        exit $?
    fi
fi

DIVIDER="============================================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

check_service() {
    local name="$1"
    local units=("${@:2}")
    local status="unknown"
    local found_unit=""

    if command -v systemctl &>/dev/null; then
        for unit in "${units[@]}"; do
            result=$(systemctl is-active "$unit" 2>/dev/null)
            if [ "$result" = "active" ]; then
                status="active"
                found_unit="$unit"
                break
            elif [ "$result" = "inactive" ] || [ "$result" = "failed" ] || [ "$result" = "activating" ]; then
                status="$result"
                found_unit="$unit"
            fi
        done
    elif command -v service &>/dev/null; then
        for unit in "${units[@]}"; do
            if service "$unit" status &>/dev/null; then
                status="active"
                found_unit="$unit"
                break
            fi
        done
    fi

    local label="${name}"
    [ -n "$found_unit" ] && label="${name} (${found_unit})"

    if [ "$status" = "active" ]; then
        echo -e "  ${label}: ${GREEN}${BOLD}RUNNING${RESET} (active)"
    elif [ "$status" = "inactive" ]; then
        echo -e "  ${label}: ${RED}${BOLD}STOPPED${RESET} (inactive)"
    elif [ "$status" = "failed" ]; then
        echo -e "  ${label}: ${RED}${BOLD}FAILED${RESET}"
    elif [ "$status" = "activating" ]; then
        echo -e "  ${label}: ${YELLOW}${BOLD}STARTING${RESET} (activating)"
    else
        echo -e "  ${name}: ${YELLOW}UNKNOWN${RESET} - not installed or not detectable"
    fi
}

echo ""
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"
echo -e "${CYAN}${BOLD}  HOST CHECK REPORT${RESET}"
echo -e "  Server IP : ${BOLD}${SERVER_IP}${RESET}"
echo -e "  Hostname  : $(hostname 2>/dev/null || echo 'N/A')"
echo -e "  Date/Time : $(date)"
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"

# --- Uptime ---
echo ""
echo -e "${BOLD}[ UPTIME ]${RESET}"
echo "  $(uptime 2>/dev/null)"
load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
echo -e "  Load avg  : ${load}"

# --- Memory ---
echo ""
echo -e "${BOLD}[ MEMORY ]${RESET}"
if command -v free &>/dev/null; then
    free -h | awk 'NR==2 { printf "  Total: %s  |  Used: %s  |  Free: %s\n", $2, $3, $4 }'
else
    echo "  Memory info not available"
fi

# --- Disk ---
echo ""
echo -e "${BOLD}[ DISK USAGE (/) ]${RESET}"
if command -v df &>/dev/null; then
    df -h / | awk 'NR==2 { printf "  Total: %s  |  Used: %s  |  Avail: %s  |  Use%%: %s\n", $2, $3, $4, $5 }'
fi

# --- MySQL / MariaDB ---
echo ""
echo -e "${BOLD}[ MYSQL STATUS ]${RESET}"
check_service "MySQL" "mysql" "mysqld" "mariadb"

if command -v mysqladmin &>/dev/null; then
    ping_result=$(mysqladmin ping 2>/dev/null)
    echo "$ping_result" | grep -q "alive" && echo -e "  Connection: ${GREEN}OK${RESET} (mysqld is alive)"
fi

# --- Apache2 ---
echo ""
echo -e "${BOLD}[ APACHE2 STATUS ]${RESET}"
check_service "Apache2" "apache2" "httpd"

if command -v ss &>/dev/null; then
    port80=$(ss -tlnp 2>/dev/null | grep -cE ':80\b')
    port443=$(ss -tlnp 2>/dev/null | grep -cE ':443\b')
    [ "$port80" -gt 0 ] && echo -e "  Port 80   : ${GREEN}LISTENING${RESET}"
    [ "$port443" -gt 0 ] && echo -e "  Port 443  : ${GREEN}LISTENING${RESET}"
fi

echo ""
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"
echo ""
