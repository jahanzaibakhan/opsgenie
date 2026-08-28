#!/usr/bin/env bash
#
# Safely reclaim disk space from duplicity cache and oversized log files.
# Run with: curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh | bash

set -u
set -o pipefail

readonly DUPLICITY_CACHE="/home/.duplicity"
readonly APP_ROOT="/home/master/applications"
readonly LOG_LIMIT_BYTES=$((100 * 1024 * 1024))
declare -a CLEANED_ITEMS=()
declare -a FAILED_ITEMS=()
declare -i EXPECTED_RECLAIMED_BYTES=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_BOLD=$'\033[1m'
    readonly C_RED=$'\033[1;31m'
    readonly C_GREEN=$'\033[1;32m'
    readonly C_YELLOW=$'\033[1;33m'
    readonly C_CYAN=$'\033[1;36m'
else
    readonly C_RESET=""
    readonly C_BOLD=""
    readonly C_RED=""
    readonly C_GREEN=""
    readonly C_YELLOW=""
    readonly C_CYAN=""
fi

section() {
    printf '\n%s============================================================\n%s\n============================================================%s\n' \
        "$C_CYAN$C_BOLD" "$1" "$C_RESET"
}

success() {
    printf '%s%s%s\n' "$C_GREEN" "$1" "$C_RESET"
}

warning() {
    printf '%s%s%s\n' "$C_YELLOW" "$1" "$C_RESET"
}

error() {
    printf '%s%s%s\n' "$C_RED" "$1" "$C_RESET" >&2
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes"
    else
        awk -v bytes="$bytes" 'BEGIN {
            split("B KiB MiB GiB TiB PiB", units, " ")
            i = 1
            while (bytes >= 1024 && i < 6) { bytes /= 1024; i++ }
            printf "%.2f %s", bytes, units[i]
        }'
    fi
}

directory_size_bytes() {
    sudo du -sxB1 "$1" 2>/dev/null | awk '{print $1}'
}

allocated_file_bytes() {
    sudo du -sB1 -- "$1" 2>/dev/null | awk '{print $1}'
}

show_disk_usage() {
    df -hT 2>/dev/null || df -h
}

free_space_bytes() {
    df -PB1 / 2>/dev/null | awk 'NR == 2 { print $4 }'
}

show_reclaimed_space() {
    local before="$1"
    local after="$2"
    local reclaimed=$((after - before))

    if (( reclaimed > 0 )); then
        success "✓ Disk space reclaimed on /: $(human_size "$reclaimed")"
    elif (( reclaimed == 0 )); then
        warning "• Free space on / did not change."
    else
        warning "• Free space on / decreased by $(human_size "$((before - after))") while the script ran."
    fi
    success "✓ Free space available on /: $(human_size "$after")"
}

show_deleted_open_files() {
    local total=0
    local threshold=$((10 * 1024 * 1024))
    local output

    section "Deleted files still held open"
    if ! command -v lsof >/dev/null 2>&1; then
        warning "• lsof is unavailable; cannot check for deleted files still held open."
        return
    fi

    output=$(sudo lsof -nP +L1 2>/dev/null |
        awk -v threshold="$threshold" '
            NR > 1 && $7 ~ /^[0-9]+$/ && $7 >= threshold {
                total += $7
                print $7 "\t" $1 "\t" $2 "\t" $9
            }
            END { if (total > 0) print "TOTAL\t" total }
        ')

    if [[ -z "$output" ]]; then
        success "✓ No deleted-but-open files of 10 MiB or larger were found."
        return
    fi

    warning "• These deleted files still consume disk space until their owning process closes or restarts:"
    while IFS=$'\t' read -r size command pid file; do
        if [[ "$size" == "TOTAL" ]]; then
            warning "• Space still held by the listed files: $(human_size "$command")"
        else
            printf '%-14s %-20s PID %-8s %s\n' "$(human_size "$size")" "$command" "$pid" "$file"
        fi
    done <<< "$output"
}

show_cleanup_reconciliation() {
    local before="$1"
    local after="$2"
    local observed=$((after - before))

    section "Cleanup space reconciliation"
    echo "Allocated blocks cleared: $(human_size "$EXPECTED_RECLAIMED_BYTES")"
    echo "Observed free-space increase: $(human_size "$(( observed > 0 ? observed : 0 ))")"

    if (( observed + (16 * 1024 * 1024) < EXPECTED_RECLAIMED_BYTES )); then
        warning "• The free-space increase is lower than the allocated blocks cleared."
        warning "• A process may still hold deleted files open, or active writes may have consumed space during cleanup."
        show_deleted_open_files
    fi
}

show_top_directories() {
    local title="$1"
    section "$title"
    printf '%s%-14s %s%s\n' "$C_BOLD" "SIZE" "DIRECTORY" "$C_RESET"
    sudo du -x -B1 --max-depth=1 / 2>/dev/null |
        sort -rn |
        awk '$2 != "/" { print $1 "\t" $2 }' |
        head -n 5 |
        while IFS=$'\t' read -r bytes path; do
            printf '%-14s %s\n' "$(human_size "$bytes")" "$path"
        done
}

show_top_applications() {
    local title="$1"
    local app_dir bytes

    section "$title"
    if [[ ! -d "$APP_ROOT" ]]; then
        echo "Application directory not found: $APP_ROOT"
        return
    fi

    printf '%s%-14s %s%s\n' "$C_BOLD" "SIZE" "APPLICATION" "$C_RESET"
    while IFS=$'\t' read -r bytes app_dir; do
        printf '%-14s %s\n' "$(human_size "$bytes")" "$app_dir"
    done < <(
        for app_dir in "$APP_ROOT"/*; do
            [[ -d "$app_dir" ]] || continue
            bytes=$(directory_size_bytes "$app_dir" || echo 0)
            printf '%s\t%s\n' "$bytes" "$(basename "$app_dir")"
        done | sort -rn | head -n 5
    )
}

is_log_file() {
    local path="$1"
    case "$path" in
        /var/log/*|*.log|*.log.[0-9]*|*.log-????????|*.out|*.err)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

clean_duplicity_cache() {
    section "Duplicity cache cleanup"
    if [[ ! -e "$DUPLICITY_CACHE" ]]; then
        warning "• No cache found at $DUPLICITY_CACHE."
        return
    fi
    if [[ ! -d "$DUPLICITY_CACHE" ]]; then
        FAILED_ITEMS+=("$DUPLICITY_CACHE (not a directory)")
        error "ERROR: $DUPLICITY_CACHE exists but is not a directory."
        return
    fi

    local bytes
    bytes=$(directory_size_bytes "$DUPLICITY_CACHE" || echo 0)
    if sudo find "$DUPLICITY_CACHE" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
        EXPECTED_RECLAIMED_BYTES+=bytes
        CLEANED_ITEMS+=("$DUPLICITY_CACHE contents ($(human_size "$bytes") removed)")
        success "✓ Cleared cache contents from $DUPLICITY_CACHE ($(human_size "$bytes"))."
    else
        FAILED_ITEMS+=("$DUPLICITY_CACHE")
        error "ERROR: Could not clear contents of $DUPLICITY_CACHE."
    fi
}

truncate_large_logs() {
    section "Log files larger than 100 MiB"
    local file apparent_bytes bytes
    local count=0

    # Search the current filesystem only. This avoids traversing mounted backups,
    # network shares, /proc, /sys, and other virtual filesystems.
    while IFS= read -r -d '' file; do
        is_log_file "$file" || continue
        apparent_bytes=$(sudo stat -c '%s' -- "$file" 2>/dev/null || echo 0)
        (( apparent_bytes > LOG_LIMIT_BYTES )) || continue
        bytes=$(allocated_file_bytes "$file" || echo 0)

        if sudo truncate -s 0 -- "$file"; then
            EXPECTED_RECLAIMED_BYTES+=bytes
            CLEANED_ITEMS+=("$file ($(human_size "$bytes") truncated)")
            success "✓ Truncated: $file ($(human_size "$bytes"))"
            ((count++))
        else
            FAILED_ITEMS+=("$file")
            error "ERROR: Could not truncate: $file"
        fi
    done < <(sudo find / -xdev -type f -size +100M -print0 2>/dev/null)

    (( count > 0 )) || warning "• No qualifying log files found."
}

main() {
    if ! command -v sudo >/dev/null 2>&1; then
        error "ERROR: sudo is required."
        exit 1
    fi

    section "Disk cleanup started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    warning "This script clears only the contents of $DUPLICITY_CACHE and truncates log files over 100 MiB."
    warning "It does not remove any of the reported top directories."
    echo
    warning "Sudo access is required; you may be prompted for your password."
    sudo -v

    local free_before free_after
    free_before=$(free_space_bytes || echo 0)
    section "Disk usage before cleanup"
    show_disk_usage
    show_top_directories "Top 5 largest root-level directories before cleanup"
    show_top_applications "Top 5 largest application directories before cleanup"

    clean_duplicity_cache
    truncate_large_logs

    section "Cleanup details"
    if (( ${#CLEANED_ITEMS[@]} > 0 )); then
        printf '%s\n' "${CLEANED_ITEMS[@]}"
    else
        warning "• No files required cleanup."
    fi

    if (( ${#FAILED_ITEMS[@]} > 0 )); then
        printf '\nItems that could not be cleaned:\n' >&2
        printf '%s\n' "${FAILED_ITEMS[@]}" >&2
    fi

    section "Disk usage after cleanup"
    show_disk_usage
    free_after=$(free_space_bytes || echo 0)
    show_reclaimed_space "$free_before" "$free_after"
    show_cleanup_reconciliation "$free_before" "$free_after"
    show_top_directories "Top 5 largest root-level directories after cleanup"
    show_top_applications "Top 5 largest application directories after cleanup"

    section "Disk cleanup completed"
}

main "$@"
