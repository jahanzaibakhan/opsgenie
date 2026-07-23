#!/bin/bash
# =============================================================
# fix-redis-stuck.sh — Fix Redis stuck in systemd restart loop
#
# Symptom: redis-server.service stuck in "deactivating (stop-sigterm)"
#          with a hung restart/stop job and port 6379 not listening.
#
# Usage:
#   sudo bash fix-redis-stuck.sh          # diagnose + fix
#   sudo bash fix-redis-stuck.sh --check  # diagnose only (no changes)
#
# Tested on: Debian/Ubuntu Cloudways servers (redis-server package)
# =============================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SERVICE="redis-server"
TIMEOUT_DROPIN="/etc/systemd/system/${SERVICE}.service.d/timeout.conf"
PID_FILE="/run/redis/redis-server.pid"
SOCK_FILE="/run/redis/redis.sock"
SYSCTL_KEY="vm.overcommit_memory"
SYSCTL_CONF="/etc/sysctl.conf"

CHECK_ONLY=false
[[ "${1:-}" == "--check" || "${1:-}" == "-n" ]] && CHECK_ONLY=true

log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

divider() { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "Run as root: sudo bash $0"
        exit 1
    fi
}

redis_active_state() {
    systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || echo "unknown"
}

redis_sub_state() {
    systemctl show "$SERVICE" -p SubState --value 2>/dev/null || echo "unknown"
}

is_stuck() {
    local active sub
    active=$(redis_active_state)
    sub=$(redis_sub_state)

    if [[ "$active" == "deactivating" ]]; then
        return 0
    fi
    if systemctl list-jobs --no-legend 2>/dev/null | grep -q "$SERVICE"; then
        return 0
    fi
    if [[ "$active" != "active" ]] && ! ss -tlnp 2>/dev/null | grep -q ':6379'; then
        return 0
    fi
    return 1
}

print_status() {
    divider
    echo -e "${BOLD}Redis / systemd status${NC}"
    divider
    systemctl status "$SERVICE" --no-pager 2>/dev/null | head -20 || true
    echo ""
    echo -e "  ActiveState : ${BOLD}$(redis_active_state)${NC}"
    echo -e "  SubState    : ${BOLD}$(redis_sub_state)${NC}"
    echo ""
    echo -e "${BOLD}Pending systemd jobs:${NC}"
    systemctl list-jobs 2>/dev/null || echo "  (none)"
    echo ""
    echo -e "${BOLD}Port 6379:${NC}"
    ss -tlnp 2>/dev/null | grep 6379 || echo "  Not listening"
    echo ""
    echo -e "${BOLD}redis-cli ping:${NC}"
    if command -v redis-cli &>/dev/null; then
        redis-cli ping 2>/dev/null || echo "  (no response)"
    else
        echo "  redis-cli not installed"
    fi
    echo ""
    echo -e "${BOLD}vm.overcommit_memory:${NC} $(sysctl -n "$SYSCTL_KEY" 2>/dev/null || echo 'unknown')"
    divider
}

cancel_stuck_jobs() {
    log "Canceling hung systemd jobs for $SERVICE..."
    local job
    while read -r job _; do
        [[ -z "$job" ]] && continue
        log "Canceling job $job"
        systemctl cancel "$job" 2>/dev/null || warn "Could not cancel job $job"
    done < <(systemctl list-jobs --no-legend 2>/dev/null | awk -v svc="$SERVICE" '$2 ~ svc {print $1}')

    log "Force-killing unit control group..."
    systemctl kill --kill-who=all --signal=SIGKILL "$SERVICE" 2>/dev/null || true

    log "Removing stale pid/socket files..."
    rm -f "$PID_FILE" "$SOCK_FILE"

    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    ok "Stuck jobs cleared"
}

install_timeout_override() {
    if [[ -f "$TIMEOUT_DROPIN" ]] && grep -q 'TimeoutStopSec=5' "$TIMEOUT_DROPIN" 2>/dev/null; then
        ok "Timeout override already present: $TIMEOUT_DROPIN"
        return
    fi

    log "Installing TimeoutStopSec=5 override..."
    mkdir -p "$(dirname "$TIMEOUT_DROPIN")"
    cat > "$TIMEOUT_DROPIN" <<'EOF'
[Service]
TimeoutStopSec=5
EOF
    systemctl daemon-reload
    ok "Installed $TIMEOUT_DROPIN"
}

force_stop_unit() {
    log "Forcing unit to inactive (dead)..."
    systemctl stop "$SERVICE" --no-block 2>/dev/null || true
    sleep 8

    local active
    active=$(redis_active_state)
    if [[ "$active" != "inactive" ]]; then
        warn "Unit still in state '$active' — running cleanup again..."
        cancel_stuck_jobs
        systemctl stop "$SERVICE" --no-block 2>/dev/null || true
        sleep 8
    fi

    active=$(redis_active_state)
    if [[ "$active" == "inactive" ]]; then
        ok "Unit is inactive (dead)"
    else
        err "Unit still not inactive (state: $active). Manual intervention may be needed."
        exit 1
    fi
}

start_redis() {
    log "Starting $SERVICE..."
    systemctl start "$SERVICE"
    sleep 3

    if systemctl is-active --quiet "$SERVICE"; then
        ok "$SERVICE is active (running)"
    else
        err "$SERVICE failed to start"
        systemctl status "$SERVICE" --no-pager || true
        exit 1
    fi
}

verify_redis() {
    log "Verifying Redis..."
    if ss -tlnp 2>/dev/null | grep -q ':6379'; then
        ok "Port 6379 is listening"
    else
        warn "Port 6379 is not listening"
    fi

    if command -v redis-cli &>/dev/null; then
        if redis-cli ping 2>/dev/null | grep -q PONG; then
            ok "redis-cli ping → PONG"
        else
            warn "redis-cli ping did not return PONG"
        fi
    fi
}

configure_overcommit() {
    log "Setting $SYSCTL_KEY=1 (helps Redis background saves)..."
    sysctl -w "$SYSCTL_KEY=1" >/dev/null

    if grep -qE '^\s*vm\.overcommit_memory\s*=' "$SYSCTL_CONF" 2>/dev/null; then
        sed -i 's/^\s*vm\.overcommit_memory\s*=.*/vm.overcommit_memory = 1/' "$SYSCTL_CONF"
    else
        echo 'vm.overcommit_memory = 1' >> "$SYSCTL_CONF"
    fi

    ok "$SYSCTL_KEY=$(sysctl -n "$SYSCTL_KEY") (persisted in $SYSCTL_CONF)"
}

main() {
    echo -e "\n${BOLD}========================================================${NC}"
    echo -e "${BOLD}  Redis stuck-service fix${NC}"
    echo -e "${BOLD}  Host: $(hostname) | $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
    echo -e "${BOLD}========================================================${NC}\n"

    require_root

    if ! systemctl list-unit-files "$SERVICE.service" &>/dev/null; then
        err "Unit $SERVICE.service not found on this server"
        exit 1
    fi

    print_status

    if [[ "$CHECK_ONLY" == true ]]; then
        if is_stuck; then
            warn "Redis appears stuck or down. Re-run without --check to fix."
            exit 2
        fi
        ok "Redis looks healthy. No fix needed."
        exit 0
    fi

    if is_stuck; then
        warn "Redis appears stuck or down — applying fix..."
    else
        log "Redis looks healthy; running preventive steps only (timeout + overcommit)..."
    fi

    cancel_stuck_jobs
    install_timeout_override

    if [[ "$(redis_active_state)" != "active" ]]; then
        force_stop_unit
        start_redis
    else
        log "Service already active — skipping stop/start"
    fi

    configure_overcommit
    verify_redis

    echo ""
    print_status
    echo -e "${GREEN}${BOLD}Done.${NC} Redis should be running. Future restarts will not hang forever (TimeoutStopSec=5).\n"
}

main "$@"
