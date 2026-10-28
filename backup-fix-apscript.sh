#!/bin/bash
# backup-fix-run.sh
# Diagnose Cloudways backup failures, apply safe remediations, then optionally
# start duplicity backup inside a detached GNU screen named "back". The
# session closes automatically after the backup, reporting, and logging finish.
#
# Usage:
#   curl -fsSL https://backups.jhanzaib.online/backup-fix-run.sh | bash
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
# Cloudways stores per-app backup dumps alongside application files, commonly
# on /mnt/data. BACKUP_WORK_DIR can override this for custom installations;
# BACKUP_TEMP_DIR remains supported for existing callers.
BACKUP_WORK_DIR="${BACKUP_WORK_DIR:-${BACKUP_TEMP_DIR:-$APPS_PATH}}"
SCREEN_NAME="back"
RUNNER="/tmp/opsgenie-backup-runner.sh"
SCRIPT_LOG_DIR="/var/cw/systeam/backup-log"
SCRIPT_LOG_FILE=""
BACKUP_REPORT_CONFIG="/etc/backup-reporting.env"
BACKUP_REPORT_URL_DEFAULT="https://backups.jhanzaib.online/api"
BACKUP_REPORT_PENDING_DIR="${SCRIPT_LOG_DIR}/pending-reports"
# Survives reboot (/tmp does not). Used to close RUNNING dashboard rows when the
# screen runner dies without sending a final FAILED report.
ACTIVE_RUN_FILE="${SCRIPT_LOG_DIR}/active-run.json"
ACTIVE_PROGRESS_FILE="${SCRIPT_LOG_DIR}/active-progress.json"
RECLAIM_SCRIPT="${SCRIPT_LOG_DIR}/reclaim-stale-run.sh"
RECLAIM_CRON_FILE="/etc/cron.d/opsgenie-backup-reclaim"
CPU_THRESHOLD=70
SWAP_THRESHOLD=50
SPACE_MULTIPLIER_PERCENT=110

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
BACKUP_RUN_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '%s-%s%s' "$(date +%s)" "$RANDOM" "$RANDOM")"

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

# Root-only file read by the watchdog/boot hook so a crash or reboot can still be reported.
save_reporting_config() {
    local config_tmp
    config_tmp=$(mktemp)
    {
        printf 'BACKUP_REPORT_URL=%q\n' "$BACKUP_REPORT_URL"
        printf 'BACKUP_REPORT_TOKEN=%q\n' "$BACKUP_REPORT_TOKEN"
        printf 'BACKUP_SERVER_IP=%q\n' "$BACKUP_SERVER_IP"
    } > "$config_tmp"
    if run_priv install -m 0600 -o root -g root "$config_tmp" "$BACKUP_REPORT_CONFIG"; then
        rm -f "$config_tmp"
        return 0
    fi
    rm -f "$config_tmp"
    return 1
}

setup_runtime_reporting() {
    local code server_ip hostname payload response

    # A token passed on the command line (per-user setup script) beats any saved file.
    if [[ -z "${BACKUP_REPORT_TOKEN:-}" && -r "$BACKUP_REPORT_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$BACKUP_REPORT_CONFIG"
        return 0
    fi
    if [[ -n "${BACKUP_REPORT_TOKEN:-}" ]]; then
        BACKUP_REPORT_URL="${BACKUP_REPORT_URL:-${BACKUP_REPORT_URL_DEFAULT}/reports}"
        BACKUP_SERVER_IP="${BACKUP_SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
        export BACKUP_REPORT_URL BACKUP_REPORT_TOKEN BACKUP_SERVER_IP
        echo -e "${GREEN}Dashboard reporting enabled with the supplied token.${NC}"
        if save_reporting_config; then
            echo -e "${GREEN}Token saved root-only on this server so a reboot or crash during the backup can still be reported.${NC}"
        else
            echo -e "${YELLOW}Could not save the token (needs root/sudo); a reboot or crash during the backup will only be caught by the dashboard's no-heartbeat check.${NC}"
        fi
        return 0
    fi
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
    BACKUP_SERVER_IP="$server_ip"
    if save_reporting_config; then
        echo -e "${GREEN}Dashboard reporting is configured for future backup runs.${NC}"
    else
        echo -e "${YELLOW}Could not save ${BACKUP_REPORT_CONFIG}; reporting is enabled only for this run.${NC}"
    fi
}

OK_MARK='"ok":true'

print_dashboard_blocked_notice() {
    echo -e "${RED}The dashboard did not accept the report from this server: bot protection on the dashboard server is answering instead of the app.${NC}"
    echo -e "${YELLOW}Fix (one time, by the dashboard admin, as root on the dashboard server): whitelist ${BACKUP_SERVER_IP:-this server IP} in Imunify360, e.g.${NC}"
    echo -e "${YELLOW}  imunify360-agent whitelist ip add ${BACKUP_SERVER_IP:-<this server IP>} --comment 'backup reporting'${NC}"
    echo -e "${YELLOW}Reports are queued on this server and will be delivered automatically after that.${NC}"
}

# Checks the token and the network path before the backup starts. Never stops the backup.
dashboard_preflight() {
    local base body rc
    [[ -n "${BACKUP_REPORT_URL:-}" && -n "${BACKUP_REPORT_TOKEN:-}" ]] || return 0
    base="${BACKUP_REPORT_URL%/reports}"
    body=$(curl -sS --connect-timeout 10 --max-time 20 -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" "${base}/ping" 2>&1)
    rc=$?
    if [[ "$body" == *"$OK_MARK"* ]]; then
        local who
        who="${body#*\"account\":\"}"
        who="${who%%\"*}"
        echo -e "${GREEN}Dashboard connection OK${who:+ (reporting to account: ${who})}.${NC}"
    elif [[ "$rc" -eq 0 && "$body" == *Unauthorized* ]]; then
        echo -e "${RED}The dashboard rejected this token (revoked or mistyped). Copy a fresh command from the Setup script button in the dashboard. The backup will still run, but nothing will be reported.${NC}"
    elif [[ "$rc" -eq 0 ]]; then
        DASHBOARD_BLOCKED=1
        print_dashboard_blocked_notice
    else
        echo -e "${YELLOW}Could not reach the dashboard right now (${body:0:120}). The backup will run; reports are retried and queued.${NC}"
    fi
}

# Single POST. If the server's own resolver fails (curl exit 6), resolve the
# dashboard through public DNS instead so a broken resolv.conf cannot drop a report.
dashboard_post() {
    local payload="$1" rc doh host ip body
    local -a args=(-fsS --connect-timeout 10 --max-time 30 -X POST "$BACKUP_REPORT_URL"
        -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" -H "Content-Type: application/json" --data "$payload")
    body=$(curl "${args[@]}")
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        # HTTP 200 is not enough: a bot-protection page also answers 200. Only the app's own JSON counts.
        [[ "$body" == *"$OK_MARK"* ]] && return 0
        DASHBOARD_BLOCKED=1
        return 77
    fi
    [[ "$rc" -eq 6 ]] || return "$rc"
    for doh in https://1.1.1.1/dns-query https://8.8.8.8/dns-query; do
        body=$(curl --doh-url "$doh" "${args[@]}" 2>/dev/null)
        if [[ "$body" == *"$OK_MARK"* ]]; then
            echo -e "${YELLOW}Local DNS failed; report sent using public DNS (${doh}).${NC}"
            return 0
        fi
    done
    host=$(printf '%s' "$BACKUP_REPORT_URL" | sed -E 's#^https?://([^/:]+).*#\1#')
    if command -v dig >/dev/null 2>&1; then
        for doh in 1.1.1.1 8.8.8.8; do
            ip=$(dig +short +time=3 +tries=1 A "$host" "@${doh}" 2>/dev/null | grep -Em1 '^[0-9]+(\.[0-9]+){3}$')
            [[ -n "$ip" ]] || continue
            body=$(curl --resolve "${host}:443:${ip}" "${args[@]}" 2>/dev/null)
            if [[ "$body" == *"$OK_MARK"* ]]; then
                echo -e "${YELLOW}Local DNS failed; report sent via ${ip} (resolved by ${doh}).${NC}"
                return 0
            fi
        done
    fi
    return "$rc"
}

spool_report() {
    local payload="$1" file
    file="${BACKUP_REPORT_PENDING_DIR}/report-$(date -u '+%Y%m%dT%H%M%SZ')-$$.json"
    if mkdir -p "$BACKUP_REPORT_PENDING_DIR" 2>/dev/null && (umask 077; printf '%s\n' "$payload" > "$file") 2>/dev/null; then
        echo -e "${YELLOW}Report queued at ${file}; it will be sent automatically on the next run.${NC}"
    else
        echo -e "${RED}Could not queue the report in ${BACKUP_REPORT_PENDING_DIR}.${NC}"
    fi
}

flush_pending_reports() {
    local file sent=0
    [[ -d "$BACKUP_REPORT_PENDING_DIR" ]] || return 0
    for file in "$BACKUP_REPORT_PENDING_DIR"/report-*.json; do
        [[ -f "$file" ]] || continue
        if dashboard_post "$(cat "$file")"; then
            rm -f "$file"
            sent=$((sent + 1))
        fi
    done
    [[ "$sent" -gt 0 ]] && echo -e "${GREEN}Delivered ${sent} previously queued dashboard report(s).${NC}"
    return 0
}

# Retries with backoff (~4 min) for transient failures (Cloudflare 522, DNS blips);
# anything still undelivered is queued on disk instead of being lost.
post_report_payload() {
    local payload="$1" attempt delay
    local -a delays=(20 40 60 120)
    for attempt in 1 2 3 4 5; do
        if dashboard_post "$payload"; then
            flush_pending_reports
            return 0
        fi
        if [[ "${DASHBOARD_BLOCKED:-0}" -eq 1 ]]; then
            print_dashboard_blocked_notice
            break
        fi
        if [[ "$attempt" -lt 5 ]]; then
            delay="${delays[$((attempt - 1))]}"
            echo -e "${YELLOW}Dashboard report attempt ${attempt}/5 failed; retrying in ${delay}s...${NC}"
            sleep "$delay"
        fi
    done
    spool_report "$payload"
    return 1
}

json_str() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Reports a run that ends without launching the backup runner. Apps still due
# are listed as NOT_STARTED so the dashboard shows what was left undone.
send_status_report() {
    local status="$1" reason="$2" hostname completed_at server_ip items="" app payload
    local -A listed=()
    [[ -n "${BACKUP_REPORT_URL:-}" && -n "${BACKUP_REPORT_TOKEN:-}" ]] || return 0
    server_ip="${BACKUP_SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
    hostname=$(hostname -f 2>/dev/null || hostname)
    completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [[ "$status" != "NO_ACTION" ]]; then
        for app in "${ELIGIBLE_APPS[@]}" "${OVERDUE_APPS[@]}"; do
            [[ -n "${listed[$app]:-}" ]] && continue
            listed[$app]=1
            items+="${items:+,}{\"app\":\"$(json_str "$app")\",\"status\":\"NOT_STARTED\",\"latestBackup\":\"$(json_str "${APP_LAST_BACKUP[$app]:-n/a}")\"}"
        done
    fi
    payload="{\"serverIp\":\"$(json_str "$server_ip")\",\"hostname\":\"$(json_str "$hostname")\",\"status\":\"${status}\",\"startedAt\":\"${BACKUP_STARTED_AT}\",\"completedAt\":\"${completed_at}\",\"apps\":[${items}]${reason:+,\"reason\":\"$(json_str "$reason")\"}}"
    if post_report_payload "$payload"; then
        echo -e "${GREEN}Backup status (${status}) sent to the central dashboard.${NC}"
    else
        echo -e "${YELLOW}Dashboard status reporting failed.${NC}"
    fi
}

send_no_action_report() {
    send_status_report NO_ACTION ""
}

# Any exit between diagnosis and launching the runner is reported as FAILED so
# a backup that never started is still visible on the dashboard.
not_started_exit() {
    local code="$1" reason="$2"
    trap - INT TERM HUP
    log_line "Backup not started: ${reason}"
    send_status_report FAILED "Backup not started: ${reason}"
    exit "$code"
}

on_interrupt_before_start() {
    echo
    not_started_exit 130 "script interrupted before the backup was launched (Ctrl+C or SSH session closed)"
}

# Close a previous dashboard RUNNING row left behind by reboot / kill -9 / crash.
report_orphaned_active_run() {
    local reason="${1:-Backup runner stopped without a final report (reboot, crash, or killed process)}"
    local payload url token completed_at
    [[ -f "$ACTIVE_PROGRESS_FILE" || -f "$ACTIVE_RUN_FILE" ]] || return 0

    # A token passed on the command line (per-user setup script) beats any saved file.
    if [[ -z "${BACKUP_REPORT_TOKEN:-}" && -r "$BACKUP_REPORT_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$BACKUP_REPORT_CONFIG"
    fi
    url="${BACKUP_REPORT_URL:-}"
    token="${BACKUP_REPORT_TOKEN:-}"
    if [[ -z "$url" || -z "$token" ]]; then
        run_priv rm -f "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE" 2>/dev/null || true
        return 0
    fi

    completed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [[ -s "$ACTIVE_PROGRESS_FILE" ]]; then
        payload=$(python3 - "$ACTIVE_PROGRESS_FILE" "$reason" "$completed_at" <<'PY' 2>/dev/null || true
import json, sys
path, reason, completed = sys.argv[1:4]
with open(path) as f:
    data = json.load(f)
apps = data.get("apps") or []
for app in apps:
    if app.get("status") in ("QUEUED", "RUNNING"):
        app["status"] = "FAILED"
data["apps"] = apps
data["status"] = "FAILED"
data["completedAt"] = completed
data["reason"] = reason
print(json.dumps(data, separators=(",", ":")))
PY
)
    fi
    if [[ -z "${payload:-}" && -s "$ACTIVE_RUN_FILE" ]]; then
        payload=$(python3 - "$ACTIVE_RUN_FILE" "$reason" "$completed_at" <<'PY' 2>/dev/null || true
import json, sys
path, reason, completed = sys.argv[1:4]
with open(path) as f:
    data = json.load(f)
payload = {
    "runId": data.get("runId"),
    "serverIp": data.get("serverIp"),
    "hostname": data.get("hostname"),
    "status": "FAILED",
    "startedAt": data.get("startedAt"),
    "completedAt": completed,
    "apps": data.get("apps") or [],
    "reason": reason,
}
print(json.dumps(payload, separators=(",", ":")))
PY
)
    fi

    if [[ -n "${payload:-}" ]]; then
        orphan_resp=$(curl -fsS --connect-timeout 5 --max-time 20 -X POST "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            --data "$payload" 2>/dev/null) || orphan_resp=""
        if [[ "$orphan_resp" == *"$OK_MARK"* ]]; then
            echo -e "${YELLOW}Closed stale dashboard run left by a previous runner.${NC}"
            log_line "Closed stale dashboard run: ${reason}"
        else
            echo -e "${YELLOW}Could not close stale dashboard run automatically; the central sweeper will mark it FAILED.${NC}"
            log_line "Failed to close stale dashboard run: ${reason}"
        fi
    fi
    run_priv rm -f "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE" 2>/dev/null || true
}

reclaim_orphaned_active_run_if_dead() {
    [[ -f "$ACTIVE_RUN_FILE" || -f "$ACTIVE_PROGRESS_FILE" ]] || return 0
    if screen_exists; then
        return 0
    fi
    if pgrep -f '/var/cw/scripts/bash/duplicity_backup\.sh|(^|[[:space:]/])opsgenie-backup-runner\.sh([[:space:]]|$)' >/dev/null 2>&1; then
        return 0
    fi
    report_orphaned_active_run "Backup runner disappeared (likely reboot or crash) before finishing"
}

install_reclaim_hook() {
    local tmp cron_tmp
    tmp=$(mktemp)
    cron_tmp=$(mktemp)
    cat > "$tmp" <<'EOF'
#!/bin/bash
# Auto-installed by backup-fix-apscript.sh. Runs every 5 minutes and once at boot (--boot).
# If a backup run was started but its runner is gone (reboot, crash, OOM kill, killed screen),
# report the true result to the dashboard: COMPLETED if backup.fact proves every app was backed up
# after the run started, otherwise FAILED with the reason.
set -u
ACTIVE_RUN_FILE='__ACTIVE_RUN_FILE__'
ACTIVE_PROGRESS_FILE='__ACTIVE_PROGRESS_FILE__'
BACKUP_REPORT_CONFIG='__BACKUP_REPORT_CONFIG__'
SCREEN_NAME='__SCREEN_NAME__'
FACTS_FILE='__FACTS_FILE__'
[[ "${1:-}" == "--boot" ]] && sleep 60
[[ -f "$ACTIVE_RUN_FILE" || -f "$ACTIVE_PROGRESS_FILE" ]] || exit 0
if screen -ls 2>/dev/null | grep -E "[[:space:]][0-9]+\.${SCREEN_NAME}[[:space:]]" >/dev/null; then
    exit 0
fi
if pgrep -f '/var/cw/scripts/bash/duplicity_backup\.sh|opsgenie-backup-runner\.sh' >/dev/null 2>&1; then
    exit 0
fi
# Never act on a run that has only just started.
for f in "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE"; do
    [[ -n "$(find "$f" -mmin -3 2>/dev/null)" ]] && exit 0
done
if [[ -r "$BACKUP_REPORT_CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP_REPORT_CONFIG"
fi
# No token saved: leave the files so the next script run can still close the row.
[[ -n "${BACKUP_REPORT_URL:-}" && -n "${BACKUP_REPORT_TOKEN:-}" ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0
src="$ACTIVE_PROGRESS_FILE"
[[ -s "$src" ]] || src="$ACTIVE_RUN_FILE"
[[ -s "$src" ]] || { rm -f "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE"; exit 0; }
payload=$(SRC="$src" FACTS_FILE="$FACTS_FILE" python3 - <<'PY' 2>/dev/null || true
import json, os, re
from datetime import datetime, timezone, timedelta

def parse_ts(value):
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except Exception:
        return None

def parse_fact(value):
    m = re.match(r"\s*(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})", value or "")
    if not m:
        return None
    d, mo, y, h, mi = map(int, m.groups())
    try:
        return datetime(y, mo, d, h, mi, tzinfo=timezone.utc)
    except ValueError:
        return None

with open(os.environ["SRC"]) as f:
    data = json.load(f)
now = datetime.now(timezone.utc)
started = parse_ts(data.get("startedAt") or "")
facts = {}
try:
    with open(os.environ["FACTS_FILE"]) as f:
        for line in f:
            if "=" in line:
                key, value = line.split("=", 1)
                facts[key.strip()] = value.strip()
except OSError:
    pass
try:
    boot = now - timedelta(seconds=float(open("/proc/uptime").read().split()[0]))
except Exception:
    boot = None
rebooted = bool(boot and started and boot > started)

apps = data.get("apps") or []
done = 0
for app in apps:
    raw = facts.get("last_backup_" + str(app.get("app", "")))
    ts = parse_fact(raw)
    if raw:
        app["latestBackup"] = raw
    if app.get("status") == "COMPLETED" or (started and ts and ts >= started - timedelta(seconds=60)):
        app["status"] = "COMPLETED"
        done += 1
    else:
        app["status"] = "FAILED"
status = "COMPLETED" if apps and done == len(apps) else "FAILED"
if status == "COMPLETED":
    reason = ("Server rebooted, but " if rebooted else "Runner stopped, but ") + "backup.fact shows every app was backed up after this run started"
elif rebooted:
    reason = "Server rebooted at %s UTC while the backup was running" % boot.strftime("%H:%M")
    if apps:
        reason += " (%d/%d app(s) had finished)" % (done, len(apps))
else:
    reason = "Backup runner stopped before finishing (process killed or crashed)"
    if apps:
        reason += " — %d/%d app(s) had finished" % (done, len(apps))
print(json.dumps({
    "runId": data.get("runId"),
    "serverIp": data.get("serverIp"),
    "hostname": data.get("hostname"),
    "status": status,
    "startedAt": data.get("startedAt"),
    "completedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "apps": apps,
    "reason": reason,
}, separators=(",", ":")))
PY
)
[[ -n "$payload" ]] || { rm -f "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE"; exit 0; }
resp=$(curl -fsS --connect-timeout 5 --max-time 20 -X POST "$BACKUP_REPORT_URL" \
    -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null) || resp=""
if [[ "$resp" == *'"ok":true'* ]]; then
    rm -f "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE"
fi
# If the dashboard could not be reached the files stay and the next 5-minute run retries.
EOF
    python3 - "$tmp" "$ACTIVE_RUN_FILE" "$ACTIVE_PROGRESS_FILE" "$BACKUP_REPORT_CONFIG" "$SCREEN_NAME" "$FACTS_FILE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
for token, value in zip(
    ("__ACTIVE_RUN_FILE__", "__ACTIVE_PROGRESS_FILE__", "__BACKUP_REPORT_CONFIG__", "__SCREEN_NAME__", "__FACTS_FILE__"),
    sys.argv[2:],
):
    text = text.replace(token, value.replace("'", "'\"'\"'"))
path.write_text(text)
PY
    printf '@reboot root %s --boot\n*/5 * * * * root %s\n' "$RECLAIM_SCRIPT" "$RECLAIM_SCRIPT" > "$cron_tmp"
    if run_priv install -m 0750 -o root -g root "$tmp" "$RECLAIM_SCRIPT" \
        && run_priv install -m 0644 -o root -g root "$cron_tmp" "$RECLAIM_CRON_FILE"; then
        :
    else
        echo -e "${YELLOW}Could not install the backup watchdog; the dashboard's no-heartbeat check still applies.${NC}"
    fi
    rm -f "$tmp" "$cron_tmp"
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
    run_priv install -d -m 0700 -o "$(id -u)" -g "$(id -g)" "$BACKUP_REPORT_PENDING_DIR" 2>/dev/null || true

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
    local work_dir="$BACKUP_WORK_DIR"
    local info filesystem available mount

    [[ "$required" -gt 0 ]] || return 0
    # If the configured work directory is the application root, use the
    # app's own directory. This follows Cloudways' applications symlink to
    # the real files mount (such as /mnt/data).
    [[ "$work_dir" == "$APPS_PATH" ]] && work_dir="$APPS_PATH/$app"
    log_section "Capacity check: ${app}"
    log_line "Database size: $(to_readable "$(( required * 100 / SPACE_MULTIPLIER_PERCENT ))")"
    log_line "Required free space on backup work mount: $(to_readable "$required")"
    info=$(mount_info "$work_dir")
    if [[ -z "$info" ]]; then
        echo -e "${RED}  Backup work directory ${work_dir}: unable to determine filesystem capacity${NC}"
        log_line "FAIL Backup work directory ${work_dir}: filesystem capacity could not be determined"
        DISK_PRESSURE_DETAILS+=("${app} backup work directory ${work_dir}: filesystem capacity could not be determined")
        return 1
    fi
    IFS=$'\t' read -r filesystem available mount <<< "$info"
    if (( available >= required )); then
        echo -e "${GREEN}  PASS Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
        log_line "PASS Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")"
        return 0
    fi

    echo -e "${RED}  FAIL Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
    log_line "FAIL Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")"
    DISK_PRESSURE_DETAILS+=("${app} backup work mount ${mount} (${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")")
    return 1
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
    if [[ -f "$ACTIVE_RUN_FILE" || -f "$ACTIVE_PROGRESS_FILE" ]]; then
        if screen_exists || pgrep -f '/var/cw/scripts/bash/duplicity_backup\.sh|opsgenie-backup-runner\.sh' >/dev/null 2>&1; then
            report_orphaned_active_run "Previous backup runner was stopped to start a new run"
        fi
    fi
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

# ---------- Imunify360: whitelist the dashboard host IP on THIS server ----------
# So the dashboard host (backup reports server) is never blocked or challenged by
# Imunify360 on this backup server. Skipped silently when Imunify360 is not installed.
# Never stops the backup. Override with DASHBOARD_HOST_IP=... or skip with SKIP_IMUNIFY_WHITELIST=1.
whitelist_dashboard_host() {
    local ip="${DASHBOARD_HOST_IP:-157.245.109.69}"
    [[ "${SKIP_IMUNIFY_WHITELIST:-0}" == "1" ]] && return 0
    if ! command -v imunify360-agent >/dev/null 2>&1; then
        echo -e "${YELLOW}Imunify360 not installed on this server; nothing to whitelist.${NC}"
        return 0
    fi
    if run_priv imunify360-agent whitelist ip list 2>/dev/null | grep -Eq "(^|[[:space:]|])${ip//./\\.}([[:space:]|/]|$)"; then
        echo -e "${GREEN}Imunify360: dashboard host ${ip} is already whitelisted.${NC}"
        return 0
    fi
    if run_priv imunify360-agent whitelist ip add "$ip" --comment "backup reports dashboard host" >/dev/null 2>&1 \
        || run_priv imunify360-agent ip-list local add --purpose white "$ip" --comment "backup reports dashboard host" >/dev/null 2>&1; then
        run_priv imunify360-agent ip-list local delete --purpose drop "$ip" >/dev/null 2>&1 || true
        echo -e "${GREEN}Imunify360: whitelisted dashboard host ${ip}.${NC}"
        REMARKS+=("Whitelisted dashboard host ${ip} in Imunify360")
    else
        echo -e "${YELLOW}Could not whitelist ${ip} in Imunify360 (continuing).${NC}"
    fi
}

setup_script_log
setup_runtime_reporting
whitelist_dashboard_host
dashboard_preflight
reclaim_orphaned_active_run_if_dead

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
    echo -e "${BOLD}▶ Step 6b: Per-app backup capacity check (${SPACE_MULTIPLIER_PERCENT}% of database size on the dump work mount)${NC}"
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
    send_no_action_report
    exit 0
fi

trap on_interrupt_before_start INT TERM HUP

if ! ask_yn "${BOLD}Diagnosis finished. Run backup now in screen named ${CYAN}${SCREEN_NAME}${NC}${BOLD}?${NC}"; then
    echo -e "${YELLOW}Backup not started. You can re-run this script later.${NC}"
    not_started_exit 0 "declined at the confirmation prompt"
fi

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
    echo -e "${RED}Backup binary missing or not executable: ${BACKUP_SCRIPT}${NC}"
    not_started_exit 1 "backup binary missing or not executable (${BACKUP_SCRIPT})"
fi

if ! have_cmd screen; then
    echo -e "${RED}GNU screen is not installed. Install it first (apt install screen).${NC}"
    not_started_exit 1 "GNU screen is not installed"
fi

if screen_exists; then
    echo -e "${YELLOW}Stopping remaining screen session '${SCREEN_NAME}' before starting the new backup.${NC}"
    screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
    sleep 1
    if screen_exists; then
        echo -e "${RED}Could not stop existing screen '${SCREEN_NAME}'. Attach and stop it manually.${NC}"
        not_started_exit 1 "could not stop the existing '${SCREEN_NAME}' screen session"
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
    printf 'BACKUP_WORK_DIR=%q\n' "$BACKUP_WORK_DIR"
    printf 'SPACE_MULTIPLIER_PERCENT=%q\n' "$SPACE_MULTIPLIER_PERCENT"
    printf 'SCRIPT_LOG_FILE=%q\n' "$SCRIPT_LOG_FILE"
    printf 'BACKUP_REPORT_CONFIG=%q\n' "$BACKUP_REPORT_CONFIG"
    printf 'BACKUP_STARTED_AT=%q\n' "$BACKUP_STARTED_AT"
    printf 'BACKUP_RUN_ID=%q\n' "$BACKUP_RUN_ID"
    printf 'BACKUP_REPORT_PENDING_DIR=%q\n' "$BACKUP_REPORT_PENDING_DIR"
    printf 'ACTIVE_RUN_FILE=%q\n' "$ACTIVE_RUN_FILE"
    printf 'ACTIVE_PROGRESS_FILE=%q\n' "$ACTIVE_PROGRESS_FILE"
    printf 'SCRIPT_LOG_DIR=%q\n' "$SCRIPT_LOG_DIR"
    printf 'OK_MARK=%q\n' "$OK_MARK"
    declare -f print_dashboard_blocked_notice dashboard_post spool_report flush_pending_reports post_report_payload
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

PROGRESS_FILE="/tmp/opsgenie-backup-progress-${BACKUP_RUN_ID}.json"
PROGRESS_ENABLED=0
PROGRESS_SERVER_IP=""
PROGRESS_HOSTNAME=""
HEARTBEAT_PID=""
PROGRESS_APPS=()
declare -A PROGRESS_STATUS=()

persist_active_run() {
    local tmp meta_tmp
    [[ -n "${ACTIVE_PROGRESS_FILE:-}" && -s "$PROGRESS_FILE" ]] || return 0
    mkdir -p "$SCRIPT_LOG_DIR" 2>/dev/null || true
    tmp="${ACTIVE_PROGRESS_FILE}.tmp"
    meta_tmp="${ACTIVE_RUN_FILE}.tmp"
    cp -f "$PROGRESS_FILE" "$tmp" 2>/dev/null && mv -f "$tmp" "$ACTIVE_PROGRESS_FILE" 2>/dev/null || true
    (umask 077; printf '{"runId":"%s","serverIp":"%s","hostname":"%s","startedAt":"%s","apps":[]}\n' \
        "$BACKUP_RUN_ID" "$(json_escape "$PROGRESS_SERVER_IP")" "$(json_escape "$PROGRESS_HOSTNAME")" \
        "$BACKUP_STARTED_AT" > "$meta_tmp") 2>/dev/null && mv -f "$meta_tmp" "$ACTIVE_RUN_FILE" 2>/dev/null || true
}

clear_active_run() {
    rm -f "${ACTIVE_RUN_FILE:-}" "${ACTIVE_PROGRESS_FILE:-}" \
        "${ACTIVE_RUN_FILE:-}.tmp" "${ACTIVE_PROGRESS_FILE:-}.tmp" 2>/dev/null || true
}

# Live progress is best-effort: one short attempt per update so a slow or
# unreachable dashboard never delays the backups themselves.
progress_post() {
    [[ "$PROGRESS_ENABLED" -eq 1 && -s "$PROGRESS_FILE" ]] || return 0
    curl -fsS --connect-timeout 5 --max-time 15 -X POST "$BACKUP_REPORT_URL" \
        -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" \
        -H "Content-Type: application/json" \
        --data-binary @"$PROGRESS_FILE" >/dev/null 2>&1 || true
}

progress_write() {
    local status="${1:-RUNNING}" reason="${2:-}" items="" app last tmp
    for app in "${PROGRESS_APPS[@]}"; do
        last=$(fact_val "last_backup_${app}")
        items+="${items:+,}{\"app\":\"$(json_escape "$app")\",\"status\":\"${PROGRESS_STATUS[$app]}\",\"latestBackup\":\"$(json_escape "${last:-n/a}")\"}"
    done
    tmp="${PROGRESS_FILE}.tmp"
    (umask 077; printf '{"runId":"%s","serverIp":"%s","hostname":"%s","status":"%s","startedAt":"%s","completedAt":"%s","apps":[%s]%s}\n' \
        "$BACKUP_RUN_ID" "$(json_escape "$PROGRESS_SERVER_IP")" "$(json_escape "$PROGRESS_HOSTNAME")" "$status" \
        "$BACKUP_STARTED_AT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$items" \
        "${reason:+,\"reason\":\"$(json_escape "$reason")\"}" > "$tmp") && mv -f "$tmp" "$PROGRESS_FILE"
    persist_active_run
}

progress_start() {
    local app
    # A token passed on the command line (per-user setup script) beats any saved file.
    if [[ -z "${BACKUP_REPORT_TOKEN:-}" && -r "$BACKUP_REPORT_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$BACKUP_REPORT_CONFIG"
    fi
    [[ -n "${BACKUP_REPORT_URL:-}" && -n "${BACKUP_REPORT_TOKEN:-}" ]] || return 0
    PROGRESS_SERVER_IP="${BACKUP_SERVER_IP:-$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
    PROGRESS_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    for app in "$@"; do
        [[ -n "$app" && -z "${PROGRESS_STATUS[$app]:-}" ]] || continue
        PROGRESS_APPS+=("$app")
        PROGRESS_STATUS[$app]="QUEUED"
    done
    PROGRESS_ENABLED=1
    progress_write
    progress_post
    # Heartbeat lets the dashboard flag a runner that died without reporting.
    ( while sleep 30 && kill -0 "$$" 2>/dev/null && [[ -f "$PROGRESS_FILE" ]]; do progress_post; done ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
    echo -e "${CYAN}Live progress is being sent to the central dashboard (run ${BACKUP_RUN_ID}).${NC}"
}

progress_set() {
    [[ "$PROGRESS_ENABLED" -eq 1 && -n "$1" ]] || return 0
    [[ -n "${PROGRESS_STATUS[$1]:-}" ]] || PROGRESS_APPS+=("$1")
    PROGRESS_STATUS[$1]="$2"
    progress_write
    progress_post
}

progress_result() {
    if [[ "$2" -eq 0 ]]; then progress_set "$1" COMPLETED; else progress_set "$1" FAILED; fi
}

progress_stop() {
    [[ -n "$HEARTBEAT_PID" ]] && pkill -P "$HEARTBEAT_PID" 2>/dev/null
    [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null
    HEARTBEAT_PID=""
    rm -f "$PROGRESS_FILE" "${PROGRESS_FILE}.tmp"
    # Keep durable active-run files until a final report is sent (or reclaim).
    return 0
}

on_runner_interrupt() {
    local app
    trap - INT TERM HUP
    trap '' PIPE
    if [[ "$PROGRESS_ENABLED" -eq 1 ]]; then
        [[ -n "$HEARTBEAT_PID" ]] && pkill -P "$HEARTBEAT_PID" 2>/dev/null
        [[ -n "$HEARTBEAT_PID" ]] && kill "$HEARTBEAT_PID" 2>/dev/null
        for app in "${PROGRESS_APPS[@]}"; do
            case "${PROGRESS_STATUS[$app]}" in QUEUED|RUNNING) PROGRESS_STATUS[$app]="FAILED" ;; esac
        done
        progress_write FAILED "Backup runner was interrupted before finishing (screen closed or process killed)"
        progress_post
        clear_active_run
    fi
    exit 130
}

report_backup_result() {
    local server_ip hostname completed_at items="" item_sep="" app rc app_status last payload

    # A token passed on the command line (per-user setup script) beats any saved file.
    if [[ -z "${BACKUP_REPORT_TOKEN:-}" && -r "$BACKUP_REPORT_CONFIG" ]]; then
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
    payload="{\"runId\":\"${BACKUP_RUN_ID}\",\"serverIp\":\"$(json_escape "$server_ip")\",\"hostname\":\"$(json_escape "$hostname")\",\"status\":\"$([[ "$FAIL" -eq 0 ]] && echo COMPLETED || echo FAILED)\",\"startedAt\":\"${BACKUP_STARTED_AT}\",\"completedAt\":\"${completed_at}\",\"apps\":[${items}]}"

    if post_report_payload "$payload"; then
        echo -e "${GREEN}Backup result sent to the central dashboard.${NC}"
        clear_active_run
    else
        echo -e "${YELLOW}Backup reporting failed after 5 attempts; the local backup result is still in ${SCRIPT_LOG_FILE}.${NC}"
        echo -e "${YELLOW}Payload (also queued for the next run):${NC}"
        echo "$payload"
        # Leave durable files so reboot reclaim / next script run can still close the row.
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
 local app="$1" db_bytes required work_dir info filesystem available mount
    db_bytes=$(sudo du -sxB1 "/var/lib/mysql/$app" 2>/dev/null | awk '{print $1}')
    db_bytes=${db_bytes:-0}
    required=$(( db_bytes * SPACE_MULTIPLIER_PERCENT / 100 ))
    [[ "$required" -gt 0 ]] || return 0
 work_dir="$BACKUP_WORK_DIR"
 [[ "$work_dir" == "$APPS_PATH" ]] && work_dir="$APPS_PATH/$app"

 echo -e "${CYAN}Capacity re-check for ${app}: DB $(to_readable "$db_bytes"), need $(to_readable "$required") on the dump work mount${NC}"
 info=$(df -PB1 "$work_dir" 2>/dev/null | awk 'NR==2 {print $1 "\t" $4 "\t" $6}')
 if [[ -z "$info" ]]; then
 echo -e "${RED}  FAIL Backup work directory ${work_dir}: cannot determine filesystem capacity${NC}"
 return 1
 fi
 IFS=$'\t' read -r filesystem available mount <<< "$info"
 if (( available >= required )); then
 echo -e "${GREEN}  PASS Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
 return 0
 fi
 echo -e "${RED}  FAIL Backup work mount (${mount}, ${work_dir}): free $(to_readable "$available"), need $(to_readable "$required")${NC}"
 return 1
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

trap progress_stop EXIT
trap on_runner_interrupt INT TERM HUP
if [[ "$FULL_BACKUP" -eq 1 ]]; then
    progress_start ALL
else
    progress_start "${APPS[@]}" "${OVERDUE_APPS[@]}"
fi

if [[ "$FULL_BACKUP" -eq 1 ]]; then
    echo -e "${YELLOW}No failed apps with data — running full server backup${NC}"
    progress_set ALL RUNNING
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
        progress_set "$APP" RUNNING
        if ! capacity_check_app "$APP"; then
            echo -e "${RED}${BOLD}SKIPPED: ${APP} no longer has sufficient free space for a safe backup.${NC}"
            RESULT_APPS+=("$APP"); RESULT_RC+=("2")
            progress_set "$APP" SKIPPED
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
        progress_result "$APP" "$rc"
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
                progress_set "$APP" SKIPPED
                FAIL=1
                continue
            fi
            FILE_SIZE=$(sudo du -sh "$APPS_PATH/$APP" 2>/dev/null | awk '{print $1}')
            DB_SIZE=$(sudo du -sh "/var/lib/mysql/$APP" 2>/dev/null | awk '{print $1}')
            [[ -n "$FILE_SIZE" ]] || FILE_SIZE="n/a"
            [[ -n "$DB_SIZE" ]] || DB_SIZE="0B"
            echo -e "${CYAN}Overdue status: ${APP} | Files: ${FILE_SIZE} | DB: ${DB_SIZE} | Eligibility: checking capacity${NC}"
            echo -e "${CYAN}${BOLD}▶ Overdue-app backup ${APP} ...${NC}"
            progress_set "$APP" RUNNING
            if ! capacity_check_app "$APP"; then
                echo -e "${RED}${BOLD}SKIPPED: ${APP} no longer has sufficient free space for a safe backup.${NC}"
                RESULT_APPS+=("$APP"); RESULT_RC+=("2")
                progress_set "$APP" SKIPPED
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
            progress_result "$APP" "$rc"
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
trap - INT TERM HUP
progress_stop
report_backup_result
echo -e "${BOLD}Runner finished $(date '+%Y-%m-%d %H:%M:%S')  fail=${FAIL}${NC}"
echo -e "${BOLD}==================================================${NC}"
echo "Backup run complete. This screen session is closing; see the dashboard and ${SCRIPT_LOG_FILE} for details."
exit "$FAIL"
RUNNER_BODY
} > "$RUNNER"
chmod 700 "$RUNNER"

# From here the runner owns reporting.
trap - INT TERM HUP

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
    not_started_exit 1 "failed to start the '${SCREEN_NAME}' screen session"
fi

# Watchdog (cron, every 5 min + at boot) closes RUNNING rows if the runner dies before finishing.
install_reclaim_hook

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
echo -e "${CYAN}The screen session closes automatically once the backup result is reported and logged.${NC}"
echo
