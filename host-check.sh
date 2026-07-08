#!/bin/bash
# host-check.sh - Quick server health check
# Usage: curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh | bash -s <SERVER_IP>

SCRIPT_URL="https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/host-check.sh"
SERVER_IP="${1:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

# ── Remote execution (jump server → target) ────────────────────────────────
if [ -n "$1" ]; then
    LOCAL_IPS=$(hostname -I 2>/dev/null)
    if ! echo "$LOCAL_IPS" | grep -qw "$1"; then

        # 1. Find cng script (Cloudways jump-server helper)
        CNG_PATH=""
        for p in "/home/${USER}/cng" "/home/master/cng" "/usr/local/bin/cng" "$(which cng 2>/dev/null)"; do
            [ -f "$p" ] && CNG_PATH="$p" && break
        done

        # 2. Parse SSH key + user from cng (it's a shell script wrapper around ssh)
        SSH_KEY="" ; SSH_USER="" ; SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"
        if [ -n "$CNG_PATH" ] && file "$CNG_PATH" 2>/dev/null | grep -qi "text"; then
            SSH_KEY=$(grep -oE '\-i [^ ]+' "$CNG_PATH" 2>/dev/null | awk '{print $2}' | head -1)
            SSH_USER=$(grep -oE '[A-Za-z0-9_]+@' "$CNG_PATH" 2>/dev/null | tr -d '@' | grep -v '^$' | tail -1)
            SSH_PORT=$(grep -oE '\-p [0-9]+' "$CNG_PATH" 2>/dev/null | awk '{print $2}' | head -1)
            [ -n "$SSH_PORT" ] && SSH_OPTS="$SSH_OPTS -p $SSH_PORT"
        fi

        # 3. Build SSH command — fall back through likely Cloudways users/keys
        SSH_USER="${SSH_USER:-systeam}"
        SSH_KEY_OPT=""
        if [ -n "$SSH_KEY" ] && [ -f "$SSH_KEY" ]; then
            SSH_KEY_OPT="-i $SSH_KEY"
        else
            for k in ~/.ssh/id_rsa ~/.ssh/id_ed25519 /home/master/.ssh/id_rsa; do
                [ -f "$k" ] && SSH_KEY_OPT="-i $k" && break
            done
        fi

        REMOTE_CMD="curl -s '${SCRIPT_URL}' | bash -s '${1}'"

        echo "Connecting to ${1} as ${SSH_USER}..."
        # shellcheck disable=SC2086
        ssh $SSH_KEY_OPT $SSH_OPTS "${SSH_USER}@${1}" "$REMOTE_CMD"
        SSH_EXIT=$?

        # 4. If first user fails, retry with other common users
        if [ $SSH_EXIT -ne 0 ]; then
            for TRY_USER in master root; do
                [ "$TRY_USER" = "$SSH_USER" ] && continue
                echo "Retrying as ${TRY_USER}..."
                # shellcheck disable=SC2086
                ssh $SSH_KEY_OPT $SSH_OPTS "${TRY_USER}@${1}" "$REMOTE_CMD" && break
                SSH_EXIT=$?
            done
        fi

        exit $SSH_EXIT
    fi
fi

# ── Local checks (runs ON the target server) ──────────────────────────────
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

    local label="${name}"
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
