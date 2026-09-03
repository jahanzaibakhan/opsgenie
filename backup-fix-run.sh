#!/bin/bash
# backup-fix-run.sh
# Diagnose Cloudways backup failures, apply safe remediations, then optionally
# start duplicity backup inside a detached GNU screen named "back".
#
# Usage:
#   curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/backup-fix-run.sh | bash
#   bash backup-fix-run.sh
#
# Attach later:  screen -r back
# Detach:        Ctrl+A then D

set -u
set -o pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

FACTS_FILE="/etc/ansible/facts.d/backup.fact"
LOG_FILE="/var/log/backup.log"
BACKUP_SCRIPT="/var/cw/scripts/bash/duplicity_backup.sh"
APPS_PATH="/home/master/applications"
DUPLICITY_CACHE="/home/.duplicity"
BACKUP_TEMP_DIR="${BACKUP_TEMP_DIR:-/tmp}"
SCREEN_NAME="back"
RUNNER="/tmp/opsgenie-backup-runner.sh"
SCRIPT_LOG_DIR="/var/cw/systeam/backup-log"
SCRIPT_LOG_FILE=""
BACKUP_REPORT_CONFIG="/etc/backup-reporting.env"
BACKUP_REPORT_URL_DEFAULT="https://backups.jhanzaib.online/api"
CPU_THRESHOLD=70
SWAP_THRESHOLD=50
SPACE_MULTIPLIER_PERCENT=120

ERROR_APPS=()
ELIGIBLE_APPS=()
OVERDUE_APPS=()
REMOVED_APPS=()
KNOWN_APPS=()
declare -A ERROR_CODES
declare -A APP_TOTAL_BYTES
declare -A APP_DB_BYTES
declare -A APP_LAST_BACKUP
declare -A APP_DUE_REASON
declare -A APP_SEEN
DISK_ERROR_FOUND=false
DISK_PRESSURE_DETAILS=()
REMARKS=()
FREQUENCY_HOURS=24
BACKUP_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# curl | bash has no stdin TTY — always talk to the real terminal when present.
TTY="/dev/tty"
if [[ ! -r "$TTY" ]]; then
    echo "No controlling terminal (/dev/tty). Re-run from an interactive SSH session."
    exit 1
fi

ask_yn() {
    local prompt="$1"
    local reply
    while true; do
        read -rp "$(echo -e "$prompt [Y/N]: ")" reply <"$TTY"
        reply=$(echo "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        case "$reply" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo -e "${RED}Please enter Y or N.${NC}" ;;
        esac
    done
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_priv() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        "$@"
    elif have_cmd sudo && sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        sudo "$@"
    fi
}

can_sudo_n() {
    [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
    have_cmd sudo && sudo -n true 2>/dev/null
}

setup_runtime_reporting() {
    local code server_ip hostname payload response

    [[ -r "$BACKUP_REPORT_CONFIG" ]] && return 0
    echo
    read -rp "Optional: paste one-time backup dashboard setup code (Enter to skip reporting): " code <"$TTY"
    [[ -n "$code" ]] || return 0

    server_ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    hostname=$(hostname -f 2>/dev/null || hostname)
    payload="{\"code\":\"${code}\",\"serverIp\":\"${server_ip}\",\"hostname\":\"${hostname}\"}"
    response=$(curl -fsS --connect-timeout 10 --max-time 30 \
        -X POST "${BACKUP_REPORT_URL_DEFAULT}/register" \
        -H "Content-Type: application/json" --data "$payload" 2>/dev/null) || {
        echo -e "${YELLOW}Dashboard registration failed; backup will run without central reporting.${NC}"
        return 0
    }
    BACKUP_REPORT_TOKEN=$(printf '%s' "$response" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    if [[ -z "$BACKUP_REPORT_TOKEN" ]]; then
        echo -e "${YELLOW}Dashboard registration returned no token; backup will run without central reporting.${NC}"
        return 0
    fi
    export BACKUP_REPORT_TOKEN
    BACKUP_REPORT_URL="${BACKUP_REPORT_URL_DEFAULT}/reports"
    export BACKUP_REPORT_URL
    echo -e "${GREEN}Dashboard reporting enabled for this backup run.${NC}"
}

setup_script_log() {
    local timestamp
    timestamp=$(LC_TIME=C date '+%d-%b-%Y-%I-%M%p')
    SCRIPT_LOG_FILE="${SCRIPT_LOG_DIR}/backup-log-${timestamp}.log"

    if ! run_priv install -d -m 0750 "$SCRIPT_LOG_DIR"; then
        echo "Could not create log directory: $SCRIPT_LOG_DIR" >&2
        exit 1
    fi
    if ! run_priv install -m 0640 -o "$(id -u)" -g "$(id -g)" /dev/null "$SCRIPT_LOG_FILE"; then
        echo "Could not create log file: $SCRIPT_LOG_FILE" >&2
        exit 1
    fi

    printf 'Backup diagnose + run started: %s\nLog path: %s\n\n' \
        "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$SCRIPT_LOG_FILE" >> "$SCRIPT_LOG_FILE"
    echo -e "${CYAN}Script output log: ${SCRIPT_LOG_FILE}${NC}"
}

log_section() {
    printf '\n==================================================\n%s\n==================================================\n' "$1" >> "$SCRIPT_LOG_FILE"
}

log_line() {
    printf '%s\n' "$1" >> "$SCRIPT_LOG_FILE"
}

trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

fact_timestamp_epoch() {
    local timestamp="${1:-}"
    local day month year hour minute
    if [[ "$timestamp" =~ ^([0-9]{2})/([0-9]{2})/([0-9]{4})[[:space:]]+([0-9]{2}):([0-9]{2})[[:space:]]+UTC$ ]]; then
        day="${BASH_REMATCH[1]}"; month="${BASH_REMATCH[2]}"; year="${BASH_REMATCH[3]}"
        hour="${BASH_REMATCH[4]}"; minute="${BASH_REMATCH[5]}"
        date -u -d "${year}-${month}-${day} ${hour}:${minute}:00 UTC" +%s 2>/dev/null
    fi
}

mount_info() {
    local path="$1"
    df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $1 "\t" $4 "\t" $6}'
}

required_space_bytes() {
    local db_bytes="${1:-0}"
    echo $(( db_bytes * SPACE_MULTIPLIER_PERCENT / 100 ))
}

capacity_check_app() {
    local app="$1"
    local required="${2:-0}"
    local label path info filesystem available mount
    local -A seen_mounts=()
    local failed=0

    [[ "$required" -gt 0 ]] || return 0
    log_section "Capacity check: ${app}"
    log_line "Database size: $(to_readable "$(( required * 100 / SPACE_MULTIPLIER_PERCENT ))")"
    log_line "Required free space: $(to_readable "$required")"
    for label in "Database:/var/lib/mysql/$app" "Application:$APPS_PATH/$app" "Temporary:$BACKUP_TEMP_DIR" "Duplicity cache:$DUPLICITY_CACHE"; do
        path="${label#*:}"
        info=$(mount_info "$path")
        if [[ -z "$info" ]]; then
            echo -e "${RED}  ${label}: unable to determine filesystem capacity${NC}"
            log_line "FAIL ${label}: unable to determine filesystem capacity"
            DISK_PRESSURE_DETAILS+=("${app} ${label}: filesystem capacity could not be determined")
            failed=1
            continue
        fi
        IFS=$'\t' read -r filesystem available mount <<< "$info"
        [[ -n "${seen_mounts[$filesystem:$mount]:-}" ]] && continue
        seen_mounts["$filesystem:$mount"]=1
        if (( available >= required )); then
            echo -e "${GREEN}  PASS ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
            log_line "PASS ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")"
        else
            echo -e "${RED}  FAIL ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
            log_line "FAIL ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")"
            DISK_PRESSURE_DETAILS+=("${app} ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")")
            failed=1
        fi
    done
    return "$failed"
}

to_bytes() {
    local size="${1:-0}"
    local num unit
    num=$(echo "$size" | sed -E 's/[^0-9.].*//')
    unit=$(echo "$size" | sed -E 's/[0-9.]+//' | tr '[:lower:]' '[:upper:]')
    [[ -z "$num" ]] && { echo 0; return; }
    case "$unit" in
        B|"") echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n}')" ;;
        K|KB) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}')" ;;
        M|MB) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}')" ;;
        G|GB) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}')" ;;
        T|TB) echo "$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}')" ;;
        *) echo 0 ;;
    esac
}

to_readable() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b >= 1073741824) printf "%.2fG", b/1073741824
        else if (b >= 1048576) printf "%.2fM", b/1048576
        else if (b >= 1024) printf "%.2fK", b/1024
        else printf "%dB", b
    }'
}

cpu_usage_pct() {
    local idle
    idle=$(awk '
        /^cpu / {
            idle=$5+$6
            total=0
            for (i=2;i<=NF;i++) total+=$i
            print idle, total
        }
    ' /proc/stat)
    sleep 1
    awk -v prev="$idle" '
        BEGIN { split(prev, p, " ") }
        /^cpu / {
            idle=$5+$6
            total=0
            for (i=2;i<=NF;i++) total+=$i
            di=idle-p[1]; dt=total-p[2]
            if (dt<=0) { print 0; exit }
            u=int((1-di/dt)*100)
            if (u<0) u=0
            if (u>100) u=100
            print u
        }
    ' /proc/stat
}

screen_exists() {
    have_cmd screen || return 1
    screen -ls 2>/dev/null | grep -E "[[:space:]][0-9]+\.${SCREEN_NAME}[[:space:]]" >/dev/null
}

stop_existing_backups() {
    local pid
    local -a backup_pids=()

    echo
    echo -e "${BOLD}▶ Preflight: stopping existing backup processes${NC}"
    while IFS= read -r pid; do
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        backup_pids+=("$pid")
    done < <(pgrep -f '/var/cw/scripts/bash/duplicity_backup\.sh|(^|[[:space:]/])duplicity([[:space:]]|$)' 2>/dev/null || true)

    if [[ ${#backup_pids[@]} -eq 0 ]]; then
        echo -e "${GREEN}No existing duplicity backup process found.${NC}"
    else
        echo -e "${YELLOW}Stopping existing backup process(es):${NC}"
        run_priv ps -fp "${backup_pids[@]}" || true
        run_priv kill -TERM "${backup_pids[@]}" 2>/dev/null || true
        sleep 5

        local -a remaining_pids=()
        for pid in "${backup_pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && remaining_pids+=("$pid")
        done
        if [[ ${#remaining_pids[@]} -gt 0 ]]; then
            echo -e "${RED}Force-stopping backup process(es): ${remaining_pids[*]}${NC}"
            run_priv kill -KILL "${remaining_pids[@]}" 2>/dev/null || true
        fi
        REMARKS+=("Stopped existing backup process(es): ${backup_pids[*]}")
    fi

    if screen_exists; then
        echo -e "${YELLOW}Stopping existing screen session '${SCREEN_NAME}'.${NC}"
        screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
        sleep 1
        REMARKS+=("Stopped existing screen session: ${SCREEN_NAME}")
    fi
}

setup_script_log
setup_runtime_reporting

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup diagnose + run (screen: ${SCREEN_NAME})${NC}"
echo -e "${BOLD} $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}==================================================${NC}"

stop_existing_backups

# ---------- 1. Duplicity cache ----------
echo
echo -e "${BOLD}▶ Step 1: Duplicity cache${NC}"
if [[ -d "$DUPLICITY_CACHE" ]]; then
    # Files only — keep directory structure (safer than rm -rf *)
    find "$DUPLICITY_CACHE" -type f -delete 2>/dev/null || run_priv find "$DUPLICITY_CACHE" -type f -delete
    echo -e "${GREEN}Duplicity cache files cleared: ${DUPLICITY_CACHE}${NC}"
    REMARKS+=("Duplicity cache cleared")
else
    echo -e "${YELLOW}Cache dir not found: ${DUPLICITY_CACHE}${NC}"
    REMARKS+=("Duplicity cache dir missing (skipped)")
fi

# ---------- 2. Resources ----------
echo
echo -e "${BOLD}▶ Step 2: CPU / memory / top processes${NC}"
echo "Load average:$(uptime | awk -F'load average:' '{print $2}')"
echo
free -h
echo
echo "Top CPU processes:"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 6

# ---------- 3. backup.fact ----------
echo
echo -e "${BOLD}▶ Step 3: ${FACTS_FILE}${NC}"
if [[ -f "$FACTS_FILE" ]]; then
    log_section "backup.fact contents (${FACTS_FILE})"
    cat "$FACTS_FILE" >> "$SCRIPT_LOG_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}${line}${NC}"
        else
            echo "$line"
        fi
    done < "$FACTS_FILE"

    while IFS='=' read -r KEY VALUE || [[ -n "${KEY:-}" ]]; do
        KEY=$(trim "${KEY:-}")
        VALUE=$(trim "${VALUE:-}")
        case "$KEY" in
            frequency)
                if [[ "$VALUE" =~ ^[0-9]+$ ]] && (( VALUE > 0 )); then
                    FREQUENCY_HOURS="$VALUE"
                else
                    echo -e "${YELLOW}Invalid frequency '${VALUE}'; using ${FREQUENCY_HOURS} hours${NC}"
                fi
                ;;
            error_code_*)
                APP_NAME="${KEY#error_code_}"
                [[ -z "$APP_NAME" ]] && continue
                APP_SEEN["$APP_NAME"]=1
                ERROR_CODES["$APP_NAME"]="$VALUE"
                if [[ "$VALUE" =~ ^[0-9]+$ ]] && [[ "$VALUE" -ne 0 ]]; then
                    ERROR_APPS+=("$APP_NAME")
                fi
                ;;
            last_backup_*)
                APP_NAME="${KEY#last_backup_}"
                [[ -z "$APP_NAME" ]] && continue
                APP_SEEN["$APP_NAME"]=1
                APP_LAST_BACKUP["$APP_NAME"]="$VALUE"
                ;;
        esac
    done < "$FACTS_FILE"

    NOW_EPOCH=$(date -u +%s)
    for APP_NAME in "${!APP_SEEN[@]}"; do
        KNOWN_APPS+=("$APP_NAME")
        LAST_BACKUP="${APP_LAST_BACKUP[$APP_NAME]:-}"
        ERROR_CODE="${ERROR_CODES[$APP_NAME]:-0}"
        if [[ "$ERROR_CODE" =~ ^[0-9]+$ ]] && (( ERROR_CODE != 0 )) &&
            [[ ! -d "$APPS_PATH/$APP_NAME" && ! -d "/var/lib/mysql/$APP_NAME" ]]; then
            APP_DUE_REASON["$APP_NAME"]="REMOVED (app and DB paths missing)"
            REMOVED_APPS+=("$APP_NAME")
        elif [[ "$ERROR_CODE" =~ ^[0-9]+$ ]] && (( ERROR_CODE != 0 )); then
            APP_DUE_REASON["$APP_NAME"]="FAILED (error ${ERROR_CODE})"
        elif [[ -z "$LAST_BACKUP" ]]; then
            APP_DUE_REASON["$APP_NAME"]="MISSING LAST BACKUP"
        else
            LAST_EPOCH=$(fact_timestamp_epoch "$LAST_BACKUP")
            if [[ ! "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
                APP_DUE_REASON["$APP_NAME"]="UNPARSEABLE LAST BACKUP"
            elif (( LAST_EPOCH > NOW_EPOCH + 300 )); then
                APP_DUE_REASON["$APP_NAME"]="FUTURE LAST BACKUP"
            elif (( NOW_EPOCH - LAST_EPOCH >= FREQUENCY_HOURS * 3600 )); then
                APP_DUE_REASON["$APP_NAME"]="OVERDUE (${FREQUENCY_HOURS}h)"
                OVERDUE_APPS+=("$APP_NAME")
            else
                APP_DUE_REASON["$APP_NAME"]="CURRENT"
            fi
        fi
    done
else
    echo -e "${RED}File not found: ${FACTS_FILE}${NC}"
    REMARKS+=("backup.fact missing")
fi

# ---------- 4. backup.log ----------
echo
echo -e "${BOLD}▶ Step 4: ${LOG_FILE}${NC}"
if [[ -f "$LOG_FILE" ]]; then
    FOUND_ERRORS=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}${line}${NC}"
            FOUND_ERRORS=true
            if [[ "$line" =~ Temp\ space\ has\ ([0-9]+)\ available,\ backup\ needs\ approx\ ([0-9]+) ]]; then
                AVAIL="${BASH_REMATCH[1]}"
                NEED="${BASH_REMATCH[2]}"
                if [[ "$AVAIL" =~ ^[0-9]+$ && "$NEED" =~ ^[0-9]+$ ]] && (( AVAIL < NEED )); then
                    DISK_ERROR_FOUND=true
                    DISK_PRESSURE_DETAILS+=("backup.log temporary space: ${AVAIL} available, ${NEED} required")
                fi
            fi
        fi
    done < <(tail -n 200 "$LOG_FILE")
    if [[ "$FOUND_ERRORS" == false ]]; then
        echo -e "${GREEN}No error lines in backup.log (showing last 30 lines)${NC}"
        tail -n 30 "$LOG_FILE"
    fi
    if grep -Ei "dump failed|mysqldump" "$LOG_FILE" >/dev/null 2>&1; then
        REMARKS+=("mysqldump / dump failure in backup.log")
    fi
else
    echo -e "${RED}File not found: ${LOG_FILE}${NC}"
    REMARKS+=("backup.log missing")
fi

# ---------- 5. Disk ----------
echo
echo -e "${BOLD}▶ Step 5: Disk usage${NC}"
df -h
log_section "Disk usage (df -h)"
df -h >> "$SCRIPT_LOG_FILE"
while read -r FS SIZE USED AVAIL USEP MOUNT; do
    [[ "${USEP:-}" == *%* ]] || continue
    USE=${USEP%\%}
    [[ "$USE" =~ ^[0-9]+$ ]] || continue
    if (( USE >= 90 )); then
        echo -e "${RED}Filesystem ${FS} on ${MOUNT} is ${USEP} full${NC}"
        DISK_ERROR_FOUND=true
        DISK_PRESSURE_DETAILS+=("${MOUNT} (${FS}) is ${USEP} full")
    fi
done < <(df -P | awk 'NR>1 {print $1,$2,$3,$4,$5,$6}')

# ---------- 6. Failed-app file and database checks ----------
echo
echo -e "${BOLD}▶ Step 6: Failed-app file and database checks${NC}"
echo "Schedule frequency: every ${FREQUENCY_HOURS} hour(s)"
if [[ ${#ERROR_APPS[@]} -eq 0 ]]; then
    echo -e "${GREEN}No failed apps in backup.fact. Overdue apps will be checked after failed-app processing.${NC}"
else
    printf "${BOLD}%-22s %-8s %-21s %-25s %-12s %-12s %-12s${NC}\n" "App" "Error" "Last backup (UTC)" "Status" "Files" "DB" "Total"
    printf "%-22s %-8s %-21s %-25s %-12s %-12s %-12s\n" "---" "-----" "-----------------" "------" "-----" "--" "-----"
    log_section "Failed/removed app status, sizes, and eligibility"
    log_line "App | Error | Last backup (UTC) | Status | Files | DB | Total"
    while IFS= read -r APP; do
        FILE_SIZE="N/A"
        FILE_BYTES=0
        DB_SIZE="0"
        DB_BYTES=0
        if [[ -d "$APPS_PATH/$APP" ]]; then
            FILE_SIZE=$(run_priv du -sh "$APPS_PATH/$APP" 2>/dev/null | awk '{print $1}')
            FILE_BYTES=$(to_bytes "$FILE_SIZE")
        fi
        if [[ -d "/var/lib/mysql/$APP" ]]; then
            DB_SIZE=$(run_priv du -sh "/var/lib/mysql/$APP" 2>/dev/null | awk '{print $1}')
            DB_BYTES=$(to_bytes "$DB_SIZE")
        fi
        TOTAL_BYTES=$(( FILE_BYTES + DB_BYTES ))
        APP_TOTAL_BYTES["$APP"]=$TOTAL_BYTES
        APP_DB_BYTES["$APP"]=$DB_BYTES
        STATUS="${APP_DUE_REASON[$APP]}"
        ERROR_CODE="${ERROR_CODES[$APP]:-0}"
        LAST_BACKUP="${APP_LAST_BACKUP[$APP]:-n/a}"
        if [[ "$STATUS" == "FAILED"* ]]; then
            STATUS_COLOR="$YELLOW"
        else
            STATUS_COLOR="$RED"
        fi
        printf "%-22s %-8s %-21s ${STATUS_COLOR}%-25s${NC} %-12s %-12s %-12s\n" \
            "$APP" "$ERROR_CODE" "$LAST_BACKUP" "$STATUS" "$FILE_SIZE" "$DB_SIZE" "$(to_readable "$TOTAL_BYTES")"
        log_line "${APP} | ${ERROR_CODE} | ${LAST_BACKUP} | ${STATUS} | ${FILE_SIZE} | ${DB_SIZE} | $(to_readable "$TOTAL_BYTES")"
        if [[ "$STATUS" == "FAILED"* && "$TOTAL_BYTES" -gt 0 ]]; then
            ELIGIBLE_APPS+=("$APP")
            log_line "Eligibility: queued for failed-app backup"
        else
            if [[ "$STATUS" == "REMOVED"* ]]; then
                echo -e "${RED}  removed ${APP}: application and database paths are both missing; backup skipped.${NC}"
                log_line "Eligibility: removed; backup skipped"
            else
                echo -e "${YELLOW}  not queued ${APP}: ${STATUS}${NC}"
                log_line "Eligibility: not queued"
            fi
        fi
    done < <(printf '%s\n' "${ERROR_APPS[@]}" | sort)
fi

# ---------- 6b. Capacity guard ----------
SPACE_SKIPPED_APPS=()
if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
    echo
    echo -e "${BOLD}▶ Step 6b: Per-app backup capacity check (120% of database size)${NC}"
    CAPACITY_ELIGIBLE_APPS=()
    for APP in "${ELIGIBLE_APPS[@]}"; do
        DB_BYTES="${APP_DB_BYTES[$APP]:-0}"
        REQUIRED_BYTES=$(required_space_bytes "$DB_BYTES")
        echo -e "${CYAN}${APP}: DB $(to_readable "$DB_BYTES"), required free space $(to_readable "$REQUIRED_BYTES")${NC}"
        if capacity_check_app "$APP" "$REQUIRED_BYTES"; then
            CAPACITY_ELIGIBLE_APPS+=("$APP")
        else
            SPACE_SKIPPED_APPS+=("$APP")
            DISK_ERROR_FOUND=true
        fi
    done
    ELIGIBLE_APPS=("${CAPACITY_ELIGIBLE_APPS[@]}")
fi

# ---------- 7. CPU remediations ----------
echo
echo -e "${BOLD}▶ Step 7: CPU check + service relief if high${NC}"
CPU_USAGE=$(cpu_usage_pct)
echo -e "${YELLOW}CPU usage: ${CPU_USAGE}%${NC}"
if [[ "$CPU_USAGE" =~ ^[0-9]+$ ]] && (( CPU_USAGE > CPU_THRESHOLD )); then
    echo -e "${RED}CPU above ${CPU_THRESHOLD}% — restarting active web/PHP/DB services${NC}"
    restarted=0
    ACTIVE_SERVICES=()
    for svc in apache2 nginx mysql mariadb; do
        if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            ACTIVE_SERVICES+=("$svc")
        fi
    done
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && ACTIVE_SERVICES+=("${svc%.service}")
    done < <(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null |
        awk '$1 ~ /^php([0-9.]+)?-fpm\.service$/ {print $1}')

    for svc in "${ACTIVE_SERVICES[@]}"; do
        if run_priv systemctl restart "$svc"; then
            echo -e "${GREEN}  restarted ${svc}${NC}"
            restarted=1
        else
            echo -e "${YELLOW}  could not restart ${svc}${NC}"
        fi
    done
    if [[ "$restarted" -eq 0 ]]; then
        echo -e "${YELLOW}No matching services found to restart${NC}"
        REMARKS+=("High CPU; no restartable services found")
    else
        REMARKS+=("High CPU; services restarted")
        sleep 2
        CPU_USAGE=$(cpu_usage_pct)
        echo -e "${YELLOW}CPU after restart: ${CPU_USAGE}%${NC}"
    fi
else
    echo -e "${GREEN}CPU is within limit${NC}"
    REMARKS+=("CPU normal (${CPU_USAGE}%)")
fi

# ---------- 8. Swap ----------
echo
echo -e "${BOLD}▶ Step 8: Swap check${NC}"
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
SWAP_TOTAL=${SWAP_TOTAL:-0}
SWAP_USED=${SWAP_USED:-0}
if [[ "$SWAP_TOTAL" -eq 0 ]]; then
    echo -e "${YELLOW}No swap configured${NC}"
    REMARKS+=("No swap")
else
    SWAP_PERCENT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
    echo "Swap: ${SWAP_USED}/${SWAP_TOTAL} MB (${SWAP_PERCENT}%)"
    if (( SWAP_PERCENT > SWAP_THRESHOLD )); then
        echo -e "${RED}Swap above ${SWAP_THRESHOLD}% — cycling swap${NC}"
        if run_priv swapoff -a && run_priv swapon -a; then
            echo -e "${GREEN}Swap cycled${NC}"
            REMARKS+=("Swap cycled")
        else
            echo -e "${RED}Failed to cycle swap${NC}"
            REMARKS+=("Swap cycle failed")
        fi
    else
        echo -e "${GREEN}Swap usage is normal${NC}"
        REMARKS+=("Swap normal (${SWAP_PERCENT}%)")
    fi
fi

# ---------- Summary ----------
echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Diagnosis summary${NC}"
echo -e "${BOLD}==================================================${NC}"
log_section "Diagnosis summary"
for r in "${REMARKS[@]}"; do
    echo " - $r"
    log_line " - $r"
done
if [[ "$DISK_ERROR_FOUND" == true ]]; then
    echo -e "${RED} - Disk capacity warnings:${NC}"
    log_line " - Disk capacity warnings:"
    for detail in "${DISK_PRESSURE_DETAILS[@]}"; do
        echo -e "${RED}   - ${detail}${NC}"
        log_line "   - ${detail}"
    done
fi
if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW} - Failed apps queued first: ${ELIGIBLE_APPS[*]}${NC}"
    log_line " - Failed apps queued first: ${ELIGIBLE_APPS[*]}"
fi
if [[ ${#OVERDUE_APPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW} - Overdue apps queued after failed-app backups: ${OVERDUE_APPS[*]}${NC}"
    log_line " - Overdue apps queued after failed-app backups: ${OVERDUE_APPS[*]}"
fi
if [[ ${#REMOVED_APPS[@]} -gt 0 ]]; then
    echo -e "${RED} - Removed apps skipped: ${REMOVED_APPS[*]}${NC}"
    log_line " - Removed apps skipped: ${REMOVED_APPS[*]}"
fi
if [[ ${#SPACE_SKIPPED_APPS[@]} -gt 0 ]]; then
    echo -e "${RED} - Apps not queued due to insufficient required-mount space: ${SPACE_SKIPPED_APPS[*]}${NC}"
    log_line " - Apps not queued due to insufficient required-mount space: ${SPACE_SKIPPED_APPS[*]}"
elif [[ ${#ERROR_APPS[@]} -gt 0 && ${#ELIGIBLE_APPS[@]} -eq 0 ]]; then
    echo -e "${YELLOW} - Failed apps listed but all have zero size${NC}"
    log_line " - Failed apps listed but all have zero size"
elif [[ ${#ERROR_APPS[@]} -eq 0 && ${#OVERDUE_APPS[@]} -eq 0 ]]; then
    echo -e "${GREEN} - No failed or overdue apps found in facts file${NC}"
    log_line " - No failed or overdue apps found in facts file"
fi
echo

# ---------- Confirm + screen ----------
if [[ ${#ELIGIBLE_APPS[@]} -eq 0 && ${#OVERDUE_APPS[@]} -eq 0 && ${#KNOWN_APPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}No backup started: all known apps are current, need review, have no data, or failed the capacity check.${NC}"
    exit 0
fi

if ! ask_yn "${BOLD}Diagnosis finished. Run backup now in screen named ${CYAN}${SCREEN_NAME}${NC}${BOLD}?${NC}"; then
    echo -e "${YELLOW}Backup not started. You can re-run this script later.${NC}"
    exit 0
fi

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
    echo -e "${RED}Backup binary missing or not executable: ${BACKUP_SCRIPT}${NC}"
    exit 1
fi

if ! have_cmd screen; then
    echo -e "${RED}GNU screen is not installed. Install it first (apt install screen).${NC}"
    exit 1
fi

if screen_exists; then
    echo -e "${YELLOW}Stopping remaining screen session '${SCREEN_NAME}' before starting the new backup.${NC}"
    screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
    sleep 1
    if screen_exists; then
        echo -e "${RED}Could not stop existing screen '${SCREEN_NAME}'. Attach and stop it manually.${NC}"
        exit 1
    fi
fi

# Build non-interactive runner for the detached session (colors + backup.fact details)
{
    printf '%s\n' '#!/bin/bash' 'set -u' 'export TERM="${TERM:-xterm-256color}"'
    printf 'BACKUP_SCRIPT=%q\n' "$BACKUP_SCRIPT"
    printf 'FACTS_FILE=%q\n' "$FACTS_FILE"
    printf 'SCREEN_NAME=%q\n' "$SCREEN_NAME"
    printf 'APPS_PATH=%q\n' "$APPS_PATH"
    printf 'DUPLICITY_CACHE=%q\n' "$DUPLICITY_CACHE"
    printf 'BACKUP_TEMP_DIR=%q\n' "$BACKUP_TEMP_DIR"
    printf 'SPACE_MULTIPLIER_PERCENT=%q\n' "$SPACE_MULTIPLIER_PERCENT"
    printf 'SCRIPT_LOG_FILE=%q\n' "$SCRIPT_LOG_FILE"
    printf 'BACKUP_REPORT_CONFIG=%q\n' "$BACKUP_REPORT_CONFIG"
    printf 'BACKUP_STARTED_AT=%q\n' "$BACKUP_STARTED_AT"
    printf 'OVERDUE_APPS=('
    for APP in "${OVERDUE_APPS[@]}"; do
        printf ' %q' "$APP"
    done
    printf ' )\n'
    if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
        printf 'APPS=('
        for APP in "${ELIGIBLE_APPS[@]}"; do
            printf ' %q' "$APP"
        done
        printf ' )\n'
        echo 'FULL_BACKUP=0'
    elif [[ ${#KNOWN_APPS[@]} -eq 0 ]]; then
        echo 'APPS=()'
        echo 'FULL_BACKUP=1'
    else
        echo 'APPS=()'
        echo 'FULL_BACKUP=0'
    fi
    cat << 'RUNNER_BODY'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

exec > >(tee -a "$SCRIPT_LOG_FILE") 2>&1
echo -e "${CYAN}Appending backup-runner output to: ${SCRIPT_LOG_FILE}${NC}"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

report_backup_result() {
    local server_ip hostname completed_at items="" item_sep="" app rc app_status last payload

    if [[ -r "$BACKUP_REPORT_CONFIG" ]]; then
        # This root-owned file supplies BACKUP_REPORT_URL, BACKUP_REPORT_TOKEN,
        # and optionally BACKUP_SERVER_IP. A registration token is otherwise
        # inherited in memory from the parent process and never written here.
        # shellcheck disable=SC1090
        source "$BACKUP_REPORT_CONFIG"
    fi
    if [[ -z "${BACKUP_REPORT_URL:-}" || -z "${BACKUP_REPORT_TOKEN:-}" ]]; then
        echo -e "${YELLOW}Backup reporting skipped: incomplete ${BACKUP_REPORT_CONFIG}.${NC}"
        return 0
    fi

    server_ip="${BACKUP_SERVER_IP:-}"
    if [[ -z "$server_ip" ]]; then
        server_ip=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    fi
    hostname=$(hostname -f 2>/dev/null || hostname)
    completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    for i in "${!RESULT_APPS[@]}"; do
        app="${RESULT_APPS[$i]}"
        rc="${RESULT_RC[$i]}"
        [[ "$rc" -eq 0 ]] && app_status="COMPLETED" || app_status="FAILED"
        last=$(fact_val "last_backup_${app}")
        item_sep="${items:+,}"
        items+="${item_sep}{\"app\":\"$(json_escape "$app")\",\"status\":\"${app_status}\",\"latestBackup\":\"$(json_escape "${last:-n/a}")\"}"
    done
    payload="{\"serverIp\":\"$(json_escape "$server_ip")\",\"hostname\":\"$(json_escape "$hostname")\",\"status\":\"$([[ "$FAIL" -eq 0 ]] && echo COMPLETED || echo FAILED)\",\"startedAt\":\"${BACKUP_STARTED_AT}\",\"completedAt\":\"${completed_at}\",\"apps\":[${items}]}"

    if curl -fsS --connect-timeout 10 --max-time 30 \
        -X POST "$BACKUP_REPORT_URL" \
        -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$payload" >/dev/null; then
        echo -e "${GREEN}Backup result sent to the central dashboard.${NC}"
    else
        echo -e "${YELLOW}Backup reporting failed; the local backup result is still in ${SCRIPT_LOG_FILE}.${NC}"
    fi
    unset BACKUP_REPORT_TOKEN
}

to_readable() {
    awk -v b="${1:-0}" 'BEGIN{
        if (b >= 1073741824) printf "%.2fG", b/1073741824
        else if (b >= 1048576) printf "%.2fM", b/1048576
        else if (b >= 1024) printf "%.2fK", b/1024
        else printf "%dB", b
    }'
}

capacity_check_app() {
    local app="$1" db_bytes required label path info filesystem available mount
    local -A seen_mounts=()
    local failed=0
    db_bytes=$(sudo du -sxB1 "/var/lib/mysql/$app" 2>/dev/null | awk '{print $1}')
    db_bytes=${db_bytes:-0}
    required=$(( db_bytes * SPACE_MULTIPLIER_PERCENT / 100 ))
    [[ "$required" -gt 0 ]] || return 0

    echo -e "${CYAN}Capacity re-check for ${app}: DB $(to_readable "$db_bytes"), need $(to_readable "$required") free${NC}"
    for label in "Database:/var/lib/mysql/$app" "Application:$APPS_PATH/$app" "Temporary:$BACKUP_TEMP_DIR" "Duplicity cache:$DUPLICITY_CACHE"; do
        path="${label#*:}"
        info=$(df -PB1 "$path" 2>/dev/null | awk 'NR==2 {print $1 "\t" $4 "\t" $6}')
        if [[ -z "$info" ]]; then
            echo -e "${RED}  FAIL ${label}: cannot determine filesystem capacity${NC}"
            failed=1
            continue
        fi
        IFS=$'\t' read -r filesystem available mount <<< "$info"
        [[ -n "${seen_mounts[$filesystem:$mount]:-}" ]] && continue
        seen_mounts["$filesystem:$mount"]=1
        if (( available >= required )); then
            echo -e "${GREEN}  PASS ${label} (${mount}): free $(to_readable "$available")${NC}"
        else
            echo -e "${RED}  FAIL ${label} (${mount}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
            failed=1
        fi
    done
    return "$failed"
}

fact_val() {
    local key="$1"
    local line val
    [[ -f "$FACTS_FILE" ]] || { echo ""; return; }
    line=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$FACTS_FILE" 2>/dev/null | tail -n 1)
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    echo "$val"
}

print_fact_block() {
    local app="$1"
    [[ -f "$FACTS_FILE" ]] || { echo "  facts file missing: $FACTS_FILE"; return; }
    grep -E "^[[:space:]]*(error_code|last_backup|backup_|status_|next_backup).*${app}" "$FACTS_FILE" 2>/dev/null \
        || grep -F "$app" "$FACTS_FILE" 2>/dev/null \
        || echo "  no matching lines for $app in $FACTS_FILE"
}

print_app_report() {
    local app="$1" rc="$2"
    local err last color label
    err=$(fact_val "error_code_${app}")
    last=$(fact_val "last_backup_${app}")
    [[ -z "$err" ]] && err="n/a"
    [[ -z "$last" ]] && last="n/a"

    if [[ "$rc" -eq 0 && "$err" == "0" ]]; then
        color="$GREEN"; label="COMPLETED"
    elif [[ "$rc" -eq 0 && "$err" != "0" && "$err" != "n/a" ]]; then
        color="$YELLOW"; label="FINISHED WITH FACT ERROR"
    elif [[ "$rc" -eq 0 ]]; then
        color="$GREEN"; label="COMPLETED"
    else
        color="$RED"; label="FAILED"
    fi

    echo -e "${color}${BOLD}--------------------------------------------------${NC}"
    echo -e "${color}${BOLD}${label}${NC}  ${BOLD}app:${NC} ${color}${app}${NC}"
    echo -e "  ${BOLD}script exit:${NC} $rc"
    echo -e "  ${BOLD}error_code_${app}:${NC} ${color}${err}${NC}"
    echo -e "  ${BOLD}last_backup_${app}:${NC} ${color}${last}${NC}"
    echo -e "  ${BOLD}from:${NC} $FACTS_FILE"
    echo -e "  ${BOLD}fact lines:${NC}"
    print_fact_block "$app" | sed 's/^/    /'
    echo -e "${color}${BOLD}--------------------------------------------------${NC}"
}

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup runner started $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD} Screen: ${SCREEN_NAME}${NC}"
echo -e "${BOLD}==================================================${NC}"

FAIL=0
declare -a RESULT_APPS RESULT_RC

if [[ "$FULL_BACKUP" -eq 1 ]]; then
    echo -e "${YELLOW}No failed apps with data — running full server backup${NC}"
    if sudo "$BACKUP_SCRIPT"; then
        rc=0
    else
        rc=$?
        FAIL=1
    fi
    if [[ -f "$FACTS_FILE" ]]; then
        mapfile -t APPS < <(grep -E '^[[:space:]]*error_code_' "$FACTS_FILE" | sed -E 's/^[[:space:]]*error_code_//;s/[[:space:]]*=.*//' )
    fi
    if [[ ${#APPS[@]} -eq 0 ]]; then
        RESULT_APPS+=("ALL"); RESULT_RC+=("$rc")
        if [[ "$rc" -eq 0 ]]; then
            echo -e "${GREEN}${BOLD}FULL BACKUP COMPLETED${NC}"
        else
            echo -e "${RED}${BOLD}FULL BACKUP FAILED${NC} (exit $rc)"
        fi
        [[ -f "$FACTS_FILE" ]] && cat "$FACTS_FILE"
    else
        for APP in "${APPS[@]}"; do
            err=$(fact_val "error_code_${APP}")
            app_rc=0
            [[ "$err" =~ ^[0-9]+$ && "$err" -ne 0 ]] && app_rc=1
            [[ "$rc" -ne 0 ]] && app_rc=1
            RESULT_APPS+=("$APP"); RESULT_RC+=("$app_rc")
            print_app_report "$APP" "$app_rc"
            [[ "$app_rc" -ne 0 ]] && FAIL=1
        done
    fi
else
    for APP in "${APPS[@]}"; do
        echo
        echo -e "${CYAN}${BOLD}▶ Failed-app backup ${APP} ...${NC}"
        if ! capacity_check_app "$APP"; then
            echo -e "${RED}${BOLD}SKIPPED: ${APP} no longer has sufficient free space for a safe backup.${NC}"
            RESULT_APPS+=("$APP"); RESULT_RC+=("2")
            FAIL=1
            continue
        fi
        if sudo "$BACKUP_SCRIPT" -a "$APP"; then
            rc=0
        else
            rc=$?
            FAIL=1
        fi
        RESULT_APPS+=("$APP"); RESULT_RC+=("$rc")
        print_app_report "$APP" "$rc"
    done

    if [[ ${#OVERDUE_APPS[@]} -gt 0 ]]; then
        echo
        echo -e "${BOLD}▶ Checking overdue apps after failed-app backups${NC}"
        for APP in "${OVERDUE_APPS[@]}"; do
            echo
            if [[ ! -d "$APPS_PATH/$APP" && ! -d "/var/lib/mysql/$APP" ]]; then
                echo -e "${RED}${BOLD}REMOVED: ${APP} application and database paths are missing; backup skipped.${NC}"
                RESULT_APPS+=("$APP"); RESULT_RC+=("3")
                FAIL=1
                continue
            fi
            FILE_SIZE=$(sudo du -sh "$APPS_PATH/$APP" 2>/dev/null | awk '{print $1}')
            DB_SIZE=$(sudo du -sh "/var/lib/mysql/$APP" 2>/dev/null | awk '{print $1}')
            [[ -n "$FILE_SIZE" ]] || FILE_SIZE="n/a"
            [[ -n "$DB_SIZE" ]] || DB_SIZE="0B"
            echo -e "${CYAN}Overdue status: ${APP} | Files: ${FILE_SIZE} | DB: ${DB_SIZE} | Eligibility: checking capacity${NC}"
            echo -e "${CYAN}${BOLD}▶ Overdue-app backup ${APP} ...${NC}"
            if ! capacity_check_app "$APP"; then
                echo -e "${RED}${BOLD}SKIPPED: ${APP} no longer has sufficient free space for a safe backup.${NC}"
                RESULT_APPS+=("$APP"); RESULT_RC+=("2")
                FAIL=1
                continue
            fi
            if sudo "$BACKUP_SCRIPT" -a "$APP"; then
                rc=0
            else
                rc=$?
                FAIL=1
            fi
            RESULT_APPS+=("$APP"); RESULT_RC+=("$rc")
            print_app_report "$APP" "$rc"
        done
    fi
fi

echo
echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup result (from ${FACTS_FILE})${NC}"
echo -e "${BOLD}==================================================${NC}"
printf "${BOLD}%-12s %-22s %s${NC}\n" "STATUS" "APP" "LATEST BACKUP (UTC)"
printf "%-12s %-22s %s\n" "------" "---" "-------------------"
for i in "${!RESULT_APPS[@]}"; do
    APP="${RESULT_APPS[$i]}"
    rc="${RESULT_RC[$i]}"
    err=$(fact_val "error_code_${APP}")
    last=$(fact_val "last_backup_${APP}")
    [[ -z "$err" ]] && err="n/a"
    [[ -z "$last" ]] && last="n/a"
    if [[ "$rc" -eq 0 && ( "$err" == "0" || "$err" == "n/a" ) ]]; then
        printf "${GREEN}${BOLD}%-12s %-22s %s${NC}\n" "COMPLETED" "$APP" "$last"
    else
        printf "${RED}${BOLD}%-12s %-22s %s${NC}\n" "FAILED" "$APP" "$last"
        FAIL=1
    fi
done

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All backups completed successfully${NC}"
else
    echo -e "${RED}${BOLD}One or more backups failed — see red lines above${NC}"
fi
report_backup_result
echo -e "${BOLD}Runner finished $(date '+%Y-%m-%d %H:%M:%S')  fail=${FAIL}${NC}"
echo -e "${BOLD}==================================================${NC}"
echo "This window stays open. Detach: Ctrl+A then D"
exec bash
RUNNER_BODY
} > "$RUNNER"
chmod 700 "$RUNNER"

# Detached start; keep a login-ish env so sudo/PATH work
if can_sudo_n; then
    screen -dmS "$SCREEN_NAME" bash "$RUNNER"
else
    echo -e "${YELLOW}sudo needs a password. Starting screen attached so you can authenticate.${NC}"
    echo -e "${CYAN}After backup starts you may detach with Ctrl+A then D.${NC}"
    screen -S "$SCREEN_NAME" bash "$RUNNER"
    exit 0
fi

# Confirm the session actually came up
sleep 1
if ! screen_exists; then
    echo -e "${RED}Failed to start screen '${SCREEN_NAME}'.${NC}"
    exit 1
fi

# Confirm the runner or duplicity is alive (brief wait)
alive=0
for _ in 1 2 3 4 5; do
    if pgrep -f "duplicity_backup.sh|${RUNNER}" >/dev/null 2>&1; then
        alive=1
        break
    fi
    sleep 1
done

echo
echo -e "${GREEN}${BOLD}Backup is initiated in screen named ${SCREEN_NAME}${NC}"
if [[ "$alive" -eq 1 ]]; then
    echo -e "${GREEN}Backup process is running inside that session.${NC}"
else
    echo -e "${YELLOW}Screen is up. Process may still be starting — attach to confirm.${NC}"
fi
if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
    echo -e "Apps queued: ${ELIGIBLE_APPS[*]}"
else
    echo "Mode: full server backup (no failed apps with data)"
fi
echo
echo -e "${CYAN}Attach:  screen -r ${SCREEN_NAME}${NC}"
echo -e "${CYAN}Detach:  Ctrl+A then D${NC}"
echo -e "${CYAN}List:    screen -ls${NC}"
echo
