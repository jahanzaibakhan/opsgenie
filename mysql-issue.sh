#!/bin/bash
# =============================================================
# mysql-issue.sh — Server MySQL Diagnostic Script v2
# Usage: sudo bash mysql-issue.sh
#        curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/mysql-issue.sh | sudo bash
# =============================================================

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

divider() { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }
header()  { echo -e "\n${BOLD}${GREEN}>>> $1${NC}"; divider; }
safe_int() { echo "${1//[^0-9]/}" | grep -o '[0-9]*' | head -1; echo 0; } # always returns integer

echo -e "\n${BOLD}========================================================${NC}"
echo -e "${BOLD}      MySQL / MariaDB Diagnostic Report v2${NC}"
echo -e "${BOLD}      Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${BOLD}========================================================${NC}"

# ── 1. Debian OS ──────────────────────────────────────────────
header "Debian OS"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo -e "  OS      : ${BOLD}$PRETTY_NAME${NC}"
    echo -e "  Version : $VERSION_ID ($VERSION_CODENAME)"
else
    echo "  /etc/os-release not found"
fi

# ── 2. Kernel Version ─────────────────────────────────────────
header "Kernel Version"
echo -e "  ${BOLD}$(uname -r)${NC}  ($(uname -m))"

# ── 3. Server Provider ────────────────────────────────────────
header "Server Provider"
PROVIDER=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
REGION=$(curl -s --max-time 3 http://169.254.169.254/metadata/v1/region 2>/dev/null \
      || curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null \
      || echo "N/A")
HOSTNAME_META=$(curl -s --max-time 3 http://169.254.169.254/metadata/v1/hostname 2>/dev/null || hostname)
echo -e "  Provider : ${BOLD}$PROVIDER${NC} ($PRODUCT)"
echo -e "  Region   : $REGION"
echo -e "  Hostname : $HOSTNAME_META"
echo -e "  IP       : $(hostname -I | awk '{print $1}')"

# ── 4. Server Creation / Boot ─────────────────────────────────
header "Server Creation / Boot Info"
BOOT_TIME=$(who -b 2>/dev/null | awk '{print $3, $4}')
OLDEST_DPKG=$(ls -lt --full-time /var/log/dpkg.log* 2>/dev/null | tail -1 | awk '{print $6, $7}' | cut -d'.' -f1)
echo -e "  Last Boot     : ${BOLD}${BOOT_TIME} UTC${NC}"
echo -e "  Uptime        : $(uptime -p 2>/dev/null || uptime)"
echo -e "  Oldest dpkg   : $OLDEST_DPKG (approx. server creation date)"

# ── 5. MariaDB / MySQL Version ────────────────────────────────
header "MariaDB / MySQL Version"
if command -v mysql &>/dev/null; then
    echo -e "  ${BOLD}$(mysql --version 2>/dev/null)${NC}"
    DB_STATUS=$(systemctl is-active mysql 2>/dev/null)
    [ "$DB_STATUS" != "active" ] && DB_STATUS=$(systemctl is-active mariadb 2>/dev/null)
    DB_PID=$(pgrep -x mariadbd 2>/dev/null || pgrep -x mysqld 2>/dev/null | head -1)
    echo -e "  Service Status : $DB_STATUS"
    [ -n "$DB_PID" ] && echo -e "  PID            : $DB_PID"
else
    echo "  MySQL/MariaDB not found"
fi

# ── 6. Last Patching Call (General + MySQL-specific) ──────────
header "Last Patching Call"

echo -e "  ${BOLD}Last 5 system upgrade/install entries:${NC}"
grep -E " upgrade | install " /var/log/dpkg.log 2>/dev/null | tail -5 | while read -r line; do
    echo "  $line"
done

echo ""
echo -e "  ${BOLD}MySQL/MariaDB specific patching history:${NC}"
# Search current and rotated dpkg logs for mysql/mariadb entries
MYSQL_PATCH=""
for dpkglog in /var/log/dpkg.log /var/log/dpkg.log.1 /var/log/dpkg.log.2.gz /var/log/dpkg.log.3.gz; do
    [ -f "$dpkglog" ] || continue
    if [[ "$dpkglog" == *.gz ]]; then
        LINES=$(zcat "$dpkglog" 2>/dev/null | grep -iE " (upgrade|install) .*(mysql|mariadb)" | tail -3)
    else
        LINES=$(grep -iE " (upgrade|install) .*(mysql|mariadb)" "$dpkglog" 2>/dev/null | tail -3)
    fi
    if [ -n "$LINES" ]; then
        echo "  [$(basename "$dpkglog")]"
        echo "$LINES" | while read -r line; do echo "    $line"; done
        MYSQL_PATCH="$LINES"
    fi
done
[ -z "$MYSQL_PATCH" ] && echo "  No MySQL/MariaDB patching entries found in dpkg logs"

# ── 7. Memory & Swap ──────────────────────────────────────────
header "Memory & Swap"
free -h | awk '
  NR==1 {printf "  %-10s %8s %8s %8s %8s %12s\n",$1,$2,$3,$4,$5,$6}
  NR==2 {printf "  %-10s %8s %8s %8s %8s %12s\n",$1,$2,$3,$4,$5,$6}
  NR==3 {printf "  %-10s %8s %8s %8s\n",$1,$2,$3,$4}
'
echo ""
SWAP_TOTAL=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
SWAP_FREE=$( awk '/SwapFree/ {print $2}' /proc/meminfo)
SWAP_TOTAL=${SWAP_TOTAL:-0}; SWAP_FREE=${SWAP_FREE:-0}
if [ "$SWAP_TOTAL" -gt 0 ]; then
    SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))
    SWAP_PCT=$((  SWAP_USED * 100 / SWAP_TOTAL ))
    if   [ "$SWAP_PCT" -ge 90 ]; then
        echo -e "  ${RED}${BOLD}WARNING SWAP CRITICAL: ${SWAP_PCT}% used ($(( SWAP_USED/1024 ))MB / $(( SWAP_TOTAL/1024 ))MB)${NC}"
    elif [ "$SWAP_PCT" -ge 70 ]; then
        echo -e "  ${YELLOW}${BOLD}WARNING SWAP HIGH: ${SWAP_PCT}% used${NC}"
    else
        echo -e "  ${GREEN}Swap OK: ${SWAP_PCT}% used${NC}"
    fi
fi

# ── 8. Running Processes (top 15 by CPU) ──────────────────────
header "Running Processes (Top 15 by CPU)"
printf "  %-8s %-12s %5s %5s  %s\n" "PID" "USER" "CPU%" "MEM%" "COMMAND"
divider
ps aux --sort=-%cpu | awk 'NR>1 && NR<=16 {
    cmd=$11; if(length(cmd)>55) cmd=substr(cmd,1,55)"..."
    printf "  %-8s %-12s %5s %5s  %s\n",$2,$1,$3,$4,cmd
}'

# ── 9. MySQL Crash History + Restart Count ────────────────────
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
    [ -z "$content" ] && { echo -e "  ${BOLD}$label${NC}: (unreadable/empty)"; return; }

    # FIX: use grep -c carefully — strip whitespace, never use || echo 0
    # (grep -c returns exit 1 on 0 matches but still prints "0" to stdout)
    local restarts
    restarts=$(echo "$content" | grep -c -E "trying to restart|pkill -9 mysql" 2>/dev/null)
    restarts=$(echo "$restarts" | tr -d '[:space:]')
    restarts=$(( ${restarts:-0} + 0 ))

    local first_crash first_crash_time
    first_crash=$(echo "$content" | grep -E "'mysql'.*(zombie|not running|failed)" | head -1)
    first_crash_time=$(echo "$first_crash" | grep -oP '\[\K[^\]]+' | head -1)

    TOTAL_RESTARTS=$(( TOTAL_RESTARTS + restarts ))

    if [ -n "$first_crash_time" ] && [ -z "$FIRST_CRASH_DATE" ]; then
        FIRST_CRASH_DATE="$first_crash_time"
        FIRST_CRASH_LOG="$label"
        FIRST_CRASH_MSG=$(echo "$first_crash" | sed "s/\[.*\] [a-z]* *: //")
    fi

    local lines
    lines=$(echo "$content" | wc -l | tr -d '[:space:]')
    echo -e "  ${BOLD}$label${NC}: ${restarts} restarts | ${lines} total lines"
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
CL_COUNT=$(grep -c -E "pkill -9 mysql|trying to restart" /var/log/monit.log 2>/dev/null)
CL_COUNT=$(echo "$CL_COUNT" | tr -d '[:space:]')
CL_COUNT=$(( ${CL_COUNT:-0} + 0 ))

if [ "$CL_COUNT" -gt 10 ]; then
    LOOP_START=$(grep -E "pkill -9 mysql|trying to restart" /var/log/monit.log 2>/dev/null | head -1 | grep -oP '\[\K[^\]]+')
    LOOP_END=$(  grep -E "pkill -9 mysql|trying to restart" /var/log/monit.log 2>/dev/null | tail -1 | grep -oP '\[\K[^\]]+')
    START_TS=$(date -d "$LOOP_START" +%s 2>/dev/null || echo 0)
    END_TS=$(  date -d "$LOOP_END"   +%s 2>/dev/null || echo 0)
    if [ "$START_TS" -gt 0 ] && [ "$END_TS" -gt "$START_TS" ]; then
        DURATION=$(( END_TS - START_TS ))
        HOURS=$(( DURATION / 3600 ))
        MINS=$((  (DURATION % 3600) / 60 ))
        SECS_PER=$(( DURATION / CL_COUNT ))
        if [ "$SECS_PER" -ge 60 ]; then RATE="$(( SECS_PER/60 )) min"
        else RATE="${SECS_PER} sec"; fi
        echo -e "  ${RED}${BOLD}WARNING: CRASH LOOP DETECTED${NC}"
        echo -e "  Loop Start : $LOOP_START"
        echo -e "  Loop End   : $LOOP_END"
        echo -e "  Duration   : ~${HOURS}h ${MINS}m"
        echo -e "  Restarts   : $CL_COUNT (current log only)"
        echo -e "  Rate       : 1 crash every ~${RATE}"
    fi
fi

echo -e "\n  ${BOLD}Total MySQL Restarts (all logs): ${RED}${TOTAL_RESTARTS}${NC}"

# ── Summary ───────────────────────────────────────────────────
echo -e "\n${BOLD}========================================================${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}========================================================${NC}"
. /etc/os-release 2>/dev/null
LAST_MYSQL_PATCH=$(
    for f in /var/log/dpkg.log /var/log/dpkg.log.1 /var/log/dpkg.log.2.gz /var/log/dpkg.log.3.gz; do
        [ -f "$f" ] || continue
        if [[ "$f" == *.gz ]]; then L=$(zcat "$f" 2>/dev/null | grep -iE " (upgrade|install) .*(mysql|mariadb)" | tail -1)
        else L=$(grep -iE " (upgrade|install) .*(mysql|mariadb)" "$f" 2>/dev/null | tail -1); fi
        [ -n "$L" ] && { echo "$L" | awk '{print $1, $2}'; break; }
    done
)
echo -e "  OS               : $PRETTY_NAME"
echo -e "  Kernel           : $(uname -r)"
echo -e "  MariaDB          : $(mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')"
echo -e "  Last System Patch: $(grep -E ' upgrade | install ' /var/log/dpkg.log 2>/dev/null | tail -1 | awk '{print $1,$2}')"
echo -e "  Last MySQL Patch : ${LAST_MYSQL_PATCH:-Not found in dpkg logs}"
echo -e "  First Crash      : ${FIRST_CRASH_DATE:-None found} (${FIRST_CRASH_LOG:-N/A})"
echo -e "  Total Restarts   : ${BOLD}${RED}${TOTAL_RESTARTS}${NC}"
[ "$SWAP_TOTAL" -gt 0 ] && \
    echo -e "  Swap Used        : ${SWAP_PCT}% ($(( (SWAP_TOTAL-SWAP_FREE)/1024 ))MB / $(( SWAP_TOTAL/1024 ))MB)" || \
    echo -e "  Swap Used        : N/A"
echo -e "${BOLD}========================================================${NC}"
echo ""
