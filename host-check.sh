#!/bin/bash
# host-check.sh - Quick server health check
# Usage: curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh | bash -s <SERVER_IP>

SERVER_IP="${1:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
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

    if command -v systemctl &>/dev/null; then
        for unit in "${units[@]}"; do
            result=$(systemctl is-active "$unit" 2>/dev/null)
            if [ "$result" = "active" ]; then
                status="active"
                break
            elif [ "$result" = "inactive" ] || [ "$result" = "failed" ]; then
                status="$result"
            fi
        done
    elif command -v service &>/dev/null; then
        for unit in "${units[@]}"; do
            service "$unit" status &>/dev/null && status="active" && break
        done
    fi

    if [ "$status" = "active" ]; then
        echo -e "  ${name}: ${GREEN}${BOLD}RUNNING${RESET} (active)"
    elif [ "$status" = "inactive" ]; then
        echo -e "  ${name}: ${RED}${BOLD}STOPPED${RESET} (inactive)"
    elif [ "$status" = "failed" ]; then
        echo -e "  ${name}: ${RED}${BOLD}FAILED${RESET}"
    else
        echo -e "  ${name}: ${YELLOW}UNKNOWN${RESET} - service not found or cannot be detected"
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
uptime_raw=$(uptime 2>/dev/null)
echo "  $uptime_raw"

# Load average breakdown
load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
echo -e "  Load avg  : ${load}"

# --- Memory ---
echo ""
echo -e "${BOLD}[ MEMORY ]${RESET}"
if command -v free &>/dev/null; then
    free -h | awk '
        NR==2 {
            printf "  Total: %s  |  Used: %s  |  Free: %s\n", $2, $3, $4
        }
    '
else
    echo "  Memory info not available (free not found)"
fi

# --- Disk ---
echo ""
echo -e "${BOLD}[ DISK USAGE (/) ]${RESET}"
if command -v df &>/dev/null; then
    df -h / | awk 'NR==2 {
        printf "  Total: %s  |  Used: %s  |  Avail: %s  |  Use%%: %s\n", $2, $3, $4, $5
    }'
else
    echo "  Disk info not available"
fi

# --- MySQL ---
echo ""
echo -e "${BOLD}[ MYSQL STATUS ]${RESET}"
check_service "MySQL" "mysql" "mysqld" "mariadb"

# Attempt a quick connection check if mysqladmin is available
if command -v mysqladmin &>/dev/null; then
    ping_result=$(mysqladmin ping 2>/dev/null)
    if echo "$ping_result" | grep -q "alive"; then
        echo -e "  Connection: ${GREEN}OK${RESET} (mysqld is alive)"
    fi
fi

# --- Apache2 ---
echo ""
echo -e "${BOLD}[ APACHE2 STATUS ]${RESET}"
check_service "Apache2" "apache2" "httpd"

# Check if port 80 or 443 is listening
if command -v ss &>/dev/null; then
    port80=$(ss -tlnp 2>/dev/null | grep -E ':80\b' | wc -l)
    port443=$(ss -tlnp 2>/dev/null | grep -E ':443\b' | wc -l)
    [ "$port80" -gt 0 ] && echo -e "  Port 80   : ${GREEN}LISTENING${RESET}"
    [ "$port443" -gt 0 ] && echo -e "  Port 443  : ${GREEN}LISTENING${RESET}"
fi

echo ""
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"
echo ""
