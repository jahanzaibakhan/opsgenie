#!/bin/bash
# =============================================================
# mysql-issue.sh — Server MySQL Diagnostic Script
# Collects: OS, Kernel, MariaDB version, Last patching,
#           First MySQL crash (monit logs), Running processes,
#           Swap memory, Provider, Restart count
# Usage: sudo bash mysql-issue.sh
# =============================================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

divider() { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }
header()  { echo -e "\n${BOLD}${GREEN}>>> $1${NC}"; divider; }

echo -e "\n${BOLD}========================================================${NC}"
echo -e "${BOLD}        MySQL / MariaDB Diagnostic Report${NC}"
echo -e "${BOLD}        Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD}========================================================${NC}"

# ── 1. Debian OS ─────────────────────────────────────────────
header "Debian OS"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "  OS      : ${BOLD}$PRETTY_NAME${NC}"
    echo -e "  Version : $VERSION_ID ($VERSION_CODENAME)"
else
    echo "  /etc/os-release not found"
fi

# ── 2. Kernel Version ────────────────────────────────────────
header "Kernel Version"
echo -e "  ${BOLD}$(uname -r)${NC}  ($(uname -m))"

# ── 3. Server Provider ───────────────────────────────────────
header "Server Provider"
PROVIDER=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
REGION=$(curl -s --max-time 3 http://169.254.169.254/metadata/v1/region 2>/dev/null || \
         curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || \
         echo "N/A")
HOSTNAME_META=$(curl -s --max-time 3 http://169.254.169.254/metadata/v1/hostname 2>/dev/null || echo "$(hostname)")
echo -e "  Provider : ${BOLD}$PROVIDER${NC} ($PRODUCT)"
echo -e "  Region   : $REGION"
echo -e "  Hostname : $HOSTNAME_META"
echo -e "  IP       : $(hostname -I | awk '{print $1}')"

# ── 4. Server Creation Date ──────────────────────────────────
header "Server Creation / Boot Info"
BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}')
OLDEST_DPKG=$(ls -lt --full-time /var/log/dpkg.log* 2>/dev/null | tail -1 | awk '{print $6, $7}' | cut -d'.' -f1)
UPTIME_INFO=$(uptime -p 2>/dev/null || uptime)
echo -e "  Last Boot     : ${BOLD}$BOOT_TIME UTC${NC}"
echo -e "  Uptime        : $UPTIME_INFO"
echo -e "  Oldest dpkg   : $OLDEST_DPKG (approx. server creation date)"

# ── 5. MariaDB / MySQL Version ───────────────────────────────
header "MariaDB / MySQL Version"
if command -v mysql &>/dev/null; then
    DB_VER=$(mysql --version 2>/dev/null)
    echo -e "  ${BOLD}$DB_VER${NC}"
    DB_STATUS=$(systemctl is-active mysql 2>/dev/null || systemctl is-active mariadb 2>/dev/null || echo "unknown")
    DB_PID=$(pgrep -x mariadbd 2>/dev/null || pgrep -x mysqld 2>/dev/null | head -1)
    echo -e "  Service Status : $DB_STATUS"
    [ -n "$DB_PID" ] && echo -e "  PID            : $DB_PID"
else
    echo "  MySQL/MariaDB not found"
fi

# ── 6. Last Patching Call ────────────────────────────────────
header "Last Patching Call"
echo -e "  ${BOLD}Latest 5 upgrade/install entries from dpkg.log:${NC}"
grep -E "upgrade|install" /var/log/dpkg.log 2>/dev/null | tail -5 | while read -r line; do
    echo "  $line"
done

# ── 7. Memory & Swap ─────────────────────────────────────────
header "Memory & Swap"
free -h | awk '
  NR==1 {printf "  %-10s %8s %8s %8s %8s %12s\n", $1, $2, $3, $4, $5, $6}
  NR==2 {printf "  %-10s %8s %8s %8s %8s %12s\n", $1, $2, $3, $4, $5, $6}
  NR==3 {printf "  %-10s %8s %8s %8s\n", $1, $2, $3, $4}
'
echo ""
SWAP_TOTAL=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
SWAP_FREE=$(awk '/SwapFree/  {print $2}' /proc/meminfo)
if [ "${SWAP_TOTAL:-0}" -gt 0 ]; then
    SWAP_USED=$((SWAP_TOTAL - SWAP_FREE))
    SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
    if   [ "$SWAP_PCT" -ge 90 ]; then
        echo -e "  ${RED}${BOLD}WARNING SWAP CRITICAL: ${SWAP_PCT}% used (${SWAP_USED}kB / ${SWAP_TOTAL}kB)${NC}"
    elif [ "$SWAP_PCT" -ge 70 ]; then
        echo -e "  ${YELLOW}${BOLD}WARNING SWAP HIGH: ${SWAP_PCT}% used${NC}"
    else
        echo -e "  ${GREEN}Swap OK: ${SWAP_PCT}% used${NC}"
    fi
fi

# ── 8. Running Processes (top 15 by CPU) ─────────────────────
header "Running Processes (Top 15 by CPU)"
printf "  %-8s %-12s %5s %5s  %s\n" "PID" "USER" "CPU%" "MEM%" "COMMAND"
divider
ps aux --sort=-%cpu | awk 'NR>1 && NR<=16 {
    cmd = $11; if (length(cmd) > 55) cmd = substr(cmd,1,55)"..."
    printf "  %-8s %-12s %5s %5s  %s\n", $2, $1, $3, $4, cmd
}'

# ── 9. MySQL Crash History + Restart Count ───────────────────
header "MySQL Crash History (from Monit Logs)"

TOTAL_RESTARTS=0
FIRST_CRASH_DATE=""
FIRST_CRASH_LOG=""
FIRST_CRASH_MSG=""

parse_monit_log() {
    local logfile="$1"
    local label="$2"
    local content

    if [[ "$logfile" == *.gz ]]; then
        content=$(zcat "$logfile" 2>/dev/null)
    else
        content=$(cat "$logfile" 2>/dev/null)
    fi
    [ -z "$content" ] && return

    local restarts
    restarts=$(echo "$content" | grep -c "trying to restart\|pkill -9 mysql" 2>/dev/null || echo 0)
    local first_crash
    first_crash=$(echo "$content" | grep -E "'mysql'.*zombie|'mysql'.*not running|'mysql'.*failed" | head -1)
    local first_crash_time
    first_crash_time=$(echo "$first_crash" | grep -oP '\[\K[^\]]+' | head -1)

    TOTAL_RESTARTS=$((TOTAL_RESTARTS + restarts))

    if [ -n "$first_crash_time" ] && [ -z "$FIRST_CRASH_DATE" ]; then
        FIRST_CRASH_DATE="$first_crash_time"
        FIRST_CRASH_LOG="$label"
        FIRST_CRASH_MSG=$(echo "$first_crash" | sed "s/\[.*\] [a-z]* *: //")
    fi

    local lines
    lines=$(echo "$content" | wc -l)
    echo -e "  ${BOLD}$label${NC}: $restarts restarts | $lines total lines"
    if [ -n "$first_crash_time" ]; then
        echo -e "    First crash : $first_crash_time"
        echo -e "    Event       : $(echo "$first_crash" | sed 's/\[.*\] [a-z]* *: //')"
    else
        echo -e "    No MySQL crashes in this log"
    fi
}

for logfile in /var/log/monit.log.2.gz /var/log/monit.log.1 /var/log/monit.log; do
    [ -f "$logfile" ] && parse_monit_log "$logfile" "$(basename "$logfile")"
done

echo ""; divider
if [ -n "$FIRST_CRASH_DATE" ]; then
    echo -e "  ${RED}${BOLD}First Genuine MySQL Crash${NC}"
    echo -e "  Log      : $FIRST_CRASH_LOG"
    echo -e "  Date/Time: ${BOLD}$FIRST_CRASH_DATE${NC}"
    echo -e "  Event    : $FIRST_CRASH_MSG"
else
    echo -e "  ${GREEN}No MySQL crashes found in monit logs.${NC}"
fi
echo ""

# Crash loop detection from current log
CURRENT_LOG_RESTARTS=$(grep -c "pkill -9 mysql\|trying to restart" /var/log/monit.log 2>/dev/null || echo 0)
if [ "${CURRENT_LOG_RESTARTS:-0}" -gt 10 ]; then
    LOOP_START=$(grep "pkill -9 mysql\|trying to restart" /var/log/monit.log 2>/dev/null | head -1 | grep -oP '\[\K[^\]]+')
    LOOP_END=$(  grep "pkill -9 mysql\|trying to restart" /var/log/monit.log 2>/dev/null | tail -1 | grep -oP '\[\K[^\]]+')
    START_TS=$(date -d "$LOOP_START" +%s 2>/dev/null || echo 0)
    END_TS=$(  date -d "$LOOP_END"   +%s 2>/dev/null || echo 0)
    if [ "$START_TS" -gt 0 ] && [ "$END_TS" -gt "$START_TS" ]; then
        DURATION=$((END_TS - START_TS))
        HOURS=$((DURATION / 3600))
        MINS=$(((DURATION % 3600) / 60))
        SECS_PER_CRASH=$((DURATION / CURRENT_LOG_RESTARTS))
        RATE="$([[ $SECS_PER_CRASH -ge 60 ]] && echo "$((SECS_PER_CRASH/60)) min" || echo "${SECS_PER_CRASH} sec")"
        echo -e "  ${RED}${BOLD}WARNING: CRASH LOOP DETECTED${NC}"
        echo -e "  Loop Start : $LOOP_START"
        echo -e "  Loop End   : $LOOP_END"
        echo -e "  Duration   : ~${HOURS}h ${MINS}m"
        echo -e "  Restarts   : $CURRENT_LOG_RESTARTS (current log only)"
        echo -e "  Rate       : 1 crash every ~${RATE}"
    fi
fi

echo -e "\n  ${BOLD}Total MySQL Restarts (all logs): ${RED}$TOTAL_RESTARTS${NC}"

# ── Final Summary ─────────────────────────────────────────────
echo -e "\n${BOLD}========================================================${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}========================================================${NC}"
. /etc/os-release 2>/dev/null
echo -e "  OS            : $PRETTY_NAME"
echo -e "  Kernel        : $(uname -r)"
echo -e "  MariaDB       : $(mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
echo -e "  Last Patch    : $(grep -E 'upgrade|install' /var/log/dpkg.log 2>/dev/null | tail -1 | awk '{print $1, $2}')"
echo -e "  First Crash   : ${FIRST_CRASH_DATE:-None found} (${FIRST_CRASH_LOG:-N/A})"
echo -e "  Total Restarts: ${BOLD}${RED}$TOTAL_RESTARTS${NC}"
[ "${SWAP_TOTAL:-0}" -gt 0 ] && \
    echo -e "  Swap Used     : ${SWAP_PCT}% ($(( (SWAP_TOTAL-SWAP_FREE)/1024 ))MB / $((SWAP_TOTAL/1024))MB)" || \
    echo -e "  Swap Used     : N/A"
echo -e "${BOLD}========================================================${NC}"
echo ""
