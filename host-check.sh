#!/bin/bash
# host-check.sh - Quick server health check
# Usage (run ON the target server):
#   curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh | bash -s <SERVER_IP>

SERVER_IP="${1:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
DIVIDER="============================================================"

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
                status="active" ; found_unit="$unit" ; break
            elif [[ "$result" =~ ^(inactive|failed|activating)$ ]]; then
                status="$result" ; found_unit="$unit"
            fi
        done
    elif command -v service &>/dev/null; then
        for unit in "${units[@]}"; do
            if service "$unit" status &>/dev/null; then
                status="active" ; found_unit="$unit" ; break
            fi
        done
    fi

    local label="$name"
    [ -n "$found_unit" ] && label="${name} (${found_unit})"

    case "$status" in
        active)     echo -e "  ${label}: ${GREEN}${BOLD}RUNNING${RESET} (active)" ;;
        inactive)   echo -e "  ${label}: ${RED}${BOLD}STOPPED${RESET} (inactive)" ;;
        failed)     echo -e "  ${label}: ${RED}${BOLD}FAILED${RESET}" ;;
        activating) echo -e "  ${label}: ${YELLOW}${BOLD}STARTING${RESET} (activating)" ;;
        *)          echo -e "  ${name}: ${YELLOW}UNKNOWN${RESET} — not installed or not detectable" ;;
    esac
}

echo ""
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"
echo -e "${CYAN}${BOLD}  HOST CHECK REPORT${RESET}"
echo -e "  Server IP : ${BOLD}${SERVER_IP}${RESET}"
echo -e "  Hostname  : $(hostname 2>/dev/null || echo 'N/A')"
echo -e "  Date/Time : $(date)"
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"

echo ""
echo -e "${BOLD}[ UPTIME ]${RESET}"
echo "  $(uptime)"
echo -e "  Load avg  : $(uptime | awk -F'load average:' '{print $2}' | xargs)"

echo ""
echo -e "${BOLD}[ MEMORY ]${RESET}"
if command -v free &>/dev/null; then
    free -h | awk 'NR==2 { printf "  Total: %s  |  Used: %s  |  Free: %s\n", $2, $3, $4 }'
else
    echo "  Memory info not available"
fi

echo ""
echo -e "${BOLD}[ DISK USAGE (/) ]${RESET}"
df -h / | awk 'NR==2 { printf "  Total: %s  |  Used: %s  |  Avail: %s  |  Use%%: %s\n", $2, $3, $4, $5 }'

echo ""
echo -e "${BOLD}[ MYSQL STATUS ]${RESET}"
check_service "MySQL" "mysql" "mysqld" "mariadb"
if command -v mysqladmin &>/dev/null; then
    mysqladmin ping 2>/dev/null | grep -q "alive" && echo -e "  Connection: ${GREEN}OK${RESET} (mysqld is alive)"
fi

echo ""
echo -e "${BOLD}[ APACHE2 STATUS ]${RESET}"
check_service "Apache2" "apache2" "httpd"
if command -v ss &>/dev/null; then
    [ "$(ss -tlnp 2>/dev/null | grep -cE ':80\b')" -gt 0 ]  && echo -e "  Port 80   : ${GREEN}LISTENING${RESET}"
    [ "$(ss -tlnp 2>/dev/null | grep -cE ':443\b')" -gt 0 ] && echo -e "  Port 443  : ${GREEN}LISTENING${RESET}"
fi

echo ""
echo -e "${CYAN}${BOLD}${DIVIDER}${RESET}"
echo ""
