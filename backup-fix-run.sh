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
SCREEN_NAME="back"
RUNNER="/tmp/opsgenie-backup-runner.sh"
CPU_THRESHOLD=70
SWAP_THRESHOLD=50

ERROR_APPS=()
ELIGIBLE_APPS=()
declare -A ERROR_CODES
declare -A APP_TOTAL_BYTES
DISK_ERROR_FOUND=false
REMARKS=()

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

echo -e "${BOLD}==================================================${NC}"
echo -e "${BOLD} Backup diagnose + run (screen: ${SCREEN_NAME})${NC}"
echo -e "${BOLD} $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo -e "${BOLD}==================================================${NC}"

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
    while IFS= read -r line || [[ -n "$line" ]]; do
        if echo "$line" | grep -qi "error"; then
            echo -e "${RED}${line}${NC}"
        else
            echo "$line"
        fi
    done < "$FACTS_FILE"

    while IFS='=' read -r KEY VALUE || [[ -n "${KEY:-}" ]]; do
        KEY=$(echo "${KEY:-}" | tr -d '[:space:]')
        VALUE=$(echo "${VALUE:-}" | tr -d '[:space:]')
        [[ "$KEY" =~ ^error_code_ ]] || continue
        APP_NAME="${KEY#error_code_}"
        [[ -z "$APP_NAME" ]] && continue
        if [[ "$VALUE" =~ ^[0-9]+$ ]] && [[ "$VALUE" -ne 0 ]]; then
            ERROR_APPS+=("$APP_NAME")
            ERROR_CODES["$APP_NAME"]="$VALUE"
            [[ "$VALUE" -ge 40 ]] && DISK_ERROR_FOUND=true
        fi
    done < "$FACTS_FILE"
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
                fi
            fi
        fi
    done < "$LOG_FILE"
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
while read -r FS SIZE USED AVAIL USEP MOUNT; do
    [[ "${USEP:-}" == *%* ]] || continue
    USE=${USEP%\%}
    [[ "$USE" =~ ^[0-9]+$ ]] || continue
    if (( USE >= 90 )); then
        echo -e "${RED}Filesystem ${FS} on ${MOUNT} is ${USEP} full${NC}"
        DISK_ERROR_FOUND=true
    fi
done < <(df -P | awk 'NR>1 {print $1,$2,$3,$4,$5,$6}')

# ---------- 6. Failed app sizes ----------
echo
echo -e "${BOLD}▶ Step 6: Failed app file + DB sizes${NC}"
if [[ ${#ERROR_APPS[@]} -eq 0 ]]; then
    echo -e "${GREEN}No failed apps in backup.fact (error_code != 0)${NC}"
else
    printf "${BOLD}%-22s %-12s %-14s %-14s %-14s${NC}\n" "App" "Err" "Files" "DB" "Total"
    printf "%-22s %-12s %-14s %-14s %-14s\n" "---" "---" "-----" "--" "-----"
    for APP in "${ERROR_APPS[@]}"; do
        FILE_SIZE="N/A"
        FILE_BYTES=0
        DB_SIZE="0"
        DB_BYTES=0
        if [[ -d "$APPS_PATH/$APP" ]]; then
            FILE_SIZE=$(du -sh "$APPS_PATH/$APP" 2>/dev/null | awk '{print $1}')
            FILE_BYTES=$(to_bytes "$FILE_SIZE")
        fi
        if [[ -d "/var/lib/mysql/$APP" ]]; then
            DB_SIZE=$(du -sh "/var/lib/mysql/$APP" 2>/dev/null | awk '{print $1}')
            DB_BYTES=$(to_bytes "$DB_SIZE")
        fi
        TOTAL_BYTES=$(( FILE_BYTES + DB_BYTES ))
        APP_TOTAL_BYTES["$APP"]=$TOTAL_BYTES
        printf "${RED}%-22s${NC} %-12s %-14s %-14s %-14s\n" \
            "$APP" "${ERROR_CODES[$APP]}" "$FILE_SIZE" "$DB_SIZE" "$(to_readable "$TOTAL_BYTES")"
        if [[ "$TOTAL_BYTES" -gt 0 ]]; then
            ELIGIBLE_APPS+=("$APP")
        else
            echo -e "${YELLOW}  skip ${APP}: file+DB size is 0${NC}"
        fi
    done
fi

# ---------- 7. CPU remediations ----------
echo
echo -e "${BOLD}▶ Step 7: CPU check + service relief if high${NC}"
CPU_USAGE=$(cpu_usage_pct)
echo -e "${YELLOW}CPU usage: ${CPU_USAGE}%${NC}"
if [[ "$CPU_USAGE" =~ ^[0-9]+$ ]] && (( CPU_USAGE > CPU_THRESHOLD )); then
    echo -e "${RED}CPU above ${CPU_THRESHOLD}% — restarting web/PHP/DB services that exist${NC}"
    restarted=0
    for svc in apache2 nginx php-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm mysql mariadb; do
        if systemctl list-unit-files "${svc}.service" 2>/dev/null | grep -q "${svc}.service"; then
            if run_priv systemctl restart "$svc"; then
                echo -e "${GREEN}  restarted ${svc}${NC}"
                restarted=1
            else
                echo -e "${YELLOW}  could not restart ${svc}${NC}"
            fi
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
for r in "${REMARKS[@]}"; do
    echo " - $r"
done
if [[ "$DISK_ERROR_FOUND" == true ]]; then
    echo -e "${RED} - Disk / temp-space pressure detected. Backup may still fail until space is freed.${NC}"
fi
if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW} - Failed apps with data: ${ELIGIBLE_APPS[*]}${NC}"
elif [[ ${#ERROR_APPS[@]} -gt 0 ]]; then
    echo -e "${YELLOW} - Failed apps listed but all have zero size${NC}"
else
    echo -e "${GREEN} - No failed apps in facts file${NC}"
fi
echo

# ---------- Confirm + screen ----------
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
    echo -e "${YELLOW}Screen session '${SCREEN_NAME}' already exists.${NC}"
    echo "  Attach: screen -r ${SCREEN_NAME}"
    if ask_yn "Kill the existing '${SCREEN_NAME}' session and start a new backup"; then
        screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
        sleep 1
        if screen_exists; then
            echo -e "${RED}Could not stop existing screen '${SCREEN_NAME}'. Attach and stop it manually.${NC}"
            exit 1
        fi
    else
        echo -e "${CYAN}Leaving existing session. Attach with: screen -r ${SCREEN_NAME}${NC}"
        exit 0
    fi
fi

# Build non-interactive runner for the detached session
{
    echo "#!/bin/bash"
    echo "set -u"
    echo "BACKUP_SCRIPT=$(printf '%q' "$BACKUP_SCRIPT")"
    echo "echo \"==================================================\""
    echo "echo \"Backup runner started \$(date '+%Y-%m-%d %H:%M:%S')\""
    echo "echo \"Screen: ${SCREEN_NAME}\""
    echo "echo \"==================================================\""
    if [[ ${#ELIGIBLE_APPS[@]} -gt 0 ]]; then
        printf "APPS=("
        for APP in "${ELIGIBLE_APPS[@]}"; do
            printf " %q" "$APP"
        done
        echo " )"
        echo "FAIL=0"
        echo "for APP in \"\${APPS[@]}\"; do"
        echo "  echo"
        echo "  echo \"▶ Backup \$APP ...\""
        echo "  if sudo \"\$BACKUP_SCRIPT\" -a \"\$APP\"; then"
        echo "    echo \"✔ Backup finished for \$APP\""
        echo "  else"
        echo "    echo \"✖ Backup failed for \$APP (exit \$?)\""
        echo "    FAIL=1"
        echo "  fi"
        echo "done"
    else
        echo "echo \"▶ No failed apps with data — running full server backup\""
        echo "FAIL=0"
        echo "if sudo \"\$BACKUP_SCRIPT\"; then"
        echo "  echo \"✔ Full backup finished\""
        echo "else"
        echo "  echo \"✖ Full backup failed (exit \$?)\""
        echo "  FAIL=1"
        echo "fi"
    fi
    echo "echo"
    echo "echo \"==================================================\""
    echo "echo \"Runner finished \$(date '+%Y-%m-%d %H:%M:%S')  fail=\$FAIL\""
    echo "echo \"==================================================\""
    echo "echo \"This window stays open. Detach: Ctrl+A then D\""
    echo "exec bash"
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
