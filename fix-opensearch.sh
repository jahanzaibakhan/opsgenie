#!/bin/bash
# =============================================================
# fix-opensearch.sh — Re-enable OpenSearch Security plugin
#
# Removes the plugins.security.disabled line from opensearch.yml,
# restarts OpenSearch, and prints service status.
#
# Usage:
#   curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/fix-opensearch.sh | sudo bash
#   sudo bash fix-opensearch.sh
#   sudo bash fix-opensearch.sh --check   # diagnose only (no changes)
#
# Tested on: Cloudways servers (opensearch package, systemd)
# =============================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG="/etc/opensearch/opensearch.yml"
SERVICE="opensearch"
BACKUP_DIR="/etc/opensearch/backups"

CHECK_ONLY=false
[[ "${1:-}" == "--check" || "${1:-}" == "-n" ]] && CHECK_ONLY=true

log()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

divider() { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        err "Run as root: curl -s https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/fix-opensearch.sh | sudo bash"
        exit 1
    fi
}

config_exists() {
    if [[ ! -f "$CONFIG" ]]; then
        err "OpenSearch config not found: $CONFIG"
        err "Is OpenSearch installed on this server?"
        exit 1
    fi
}

service_exists() {
    if ! systemctl list-unit-files "${SERVICE}.service" &>/dev/null; then
        err "Unit ${SERVICE}.service not found on this server"
        exit 1
    fi
}

find_disable_lines() {
    grep -nE '^[[:space:]]*#?[[:space:]]*plugins\.security\.disabled[[:space:]]*:' "$CONFIG" 2>/dev/null || true
}

has_disable_line() {
    grep -qE '^[[:space:]]*plugins\.security\.disabled[[:space:]]*:' "$CONFIG" 2>/dev/null
}

print_status() {
    divider
    echo -e "${BOLD}OpenSearch service status${NC}"
    divider
    systemctl status "$SERVICE" --no-pager 2>/dev/null | head -25 || true
    echo ""
    echo -e "${BOLD}ActiveState:${NC} $(systemctl show "$SERVICE" -p ActiveState --value 2>/dev/null || echo 'unknown')"
    echo -e "${BOLD}SubState:${NC}    $(systemctl show "$SERVICE" -p SubState --value 2>/dev/null || echo 'unknown')"
    divider
}

remove_disable_line() {
    local stamp backup removed
    stamp=$(date '+%Y%m%d-%H%M%S')
    backup="${BACKUP_DIR}/opensearch.yml.${stamp}.bak"

    mkdir -p "$BACKUP_DIR"
    cp -a "$CONFIG" "$backup"
    ok "Backup saved: $backup"

    log "Removing plugins.security.disabled from $CONFIG ..."

    # Drop active and commented disable lines (common manual fix after failed demo install)
    sed -i -E '/^[[:space:]]*#?[[:space:]]*plugins\.security\.disabled[[:space:]]*:/d' "$CONFIG"

    if has_disable_line; then
        err "Could not remove plugins.security.disabled — edit $CONFIG manually"
        exit 1
    fi

    removed=$(grep -cE 'plugins\.security\.disabled' "$backup" 2>/dev/null || echo 0)
    ok "Removed plugin disable line(s) from opensearch.yml (matched in backup: $removed)"
}

restart_opensearch() {
    log "Restarting $SERVICE ..."
    systemctl restart "$SERVICE"
    sleep 5

    if systemctl is-active --quiet "$SERVICE"; then
        ok "$SERVICE is active (running)"
    else
        err "$SERVICE failed to start after restart"
        systemctl status "$SERVICE" --no-pager || true
        warn "Restore backup from $BACKUP_DIR if needed"
        exit 1
    fi
}

main() {
    echo -e "\n${BOLD}========================================================${NC}"
    echo -e "${BOLD}  OpenSearch fix — re-enable security plugin${NC}"
    echo -e "${BOLD}  Host: $(hostname) | $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
    echo -e "${BOLD}========================================================${NC}\n"

    require_root
    config_exists
    service_exists

    divider
    echo -e "${BOLD}Current plugin disable lines in $CONFIG:${NC}"
    matches=$(find_disable_lines)
    if [[ -n "$matches" ]]; then
        echo "$matches"
    else
        echo "  (none found)"
    fi
    divider

    if [[ "$CHECK_ONLY" == true ]]; then
        if has_disable_line; then
            warn "plugins.security.disabled is still set. Re-run without --check to fix."
            print_status
            exit 2
        fi
        ok "No active plugins.security.disabled line — OpenSearch config looks correct."
        print_status
        exit 0
    fi

    if has_disable_line; then
        remove_disable_line
        restart_opensearch
    else
        ok "plugins.security.disabled not present — skipping config edit"
        if ! systemctl is-active --quiet "$SERVICE"; then
            warn "$SERVICE is not active — attempting restart ..."
            restart_opensearch
        else
            log "$SERVICE already active — no restart required"
        fi
    fi

    echo ""
    print_status
    echo -e "${GREEN}${BOLD}Done.${NC} OpenSearch security plugin should be enabled.\n"
}

main "$@"
