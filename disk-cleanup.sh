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

section() {
    printf '\n============================================================\n%s\n============================================================\n' "$1"
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

show_disk_usage() {
    df -hT 2>/dev/null || df -h
}

show_top_directories() {
    local title="$1"
    section "$title"
    printf '%-14s %s\n' "SIZE" "DIRECTORY"
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

    printf '%-14s %s\n' "SIZE" "APPLICATION"
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
        echo "No cache found at $DUPLICITY_CACHE."
        return
    fi
    if [[ ! -d "$DUPLICITY_CACHE" ]]; then
        FAILED_ITEMS+=("$DUPLICITY_CACHE (not a directory)")
        echo "ERROR: $DUPLICITY_CACHE exists but is not a directory." >&2
        return
    fi

    local bytes
    bytes=$(directory_size_bytes "$DUPLICITY_CACHE" || echo 0)
    if sudo find "$DUPLICITY_CACHE" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; then
        CLEANED_ITEMS+=("$DUPLICITY_CACHE contents ($(human_size "$bytes") removed)")
        echo "Removed cache contents from $DUPLICITY_CACHE ($(human_size "$bytes"))."
    else
        FAILED_ITEMS+=("$DUPLICITY_CACHE")
        echo "ERROR: Could not clear contents of $DUPLICITY_CACHE." >&2
    fi
}

truncate_large_logs() {
    section "Log files larger than 100 MiB"
    local file bytes
    local count=0

    # Search the current filesystem only. This avoids traversing mounted backups,
    # network shares, /proc, /sys, and other virtual filesystems.
    while IFS= read -r -d '' file; do
        is_log_file "$file" || continue
        bytes=$(sudo stat -c '%s' -- "$file" 2>/dev/null || echo 0)
        (( bytes > LOG_LIMIT_BYTES )) || continue

        if sudo truncate -s 0 -- "$file"; then
            CLEANED_ITEMS+=("$file ($(human_size "$bytes") truncated)")
            printf 'Truncated: %s (%s)\n' "$file" "$(human_size "$bytes")"
            ((count++))
        else
            FAILED_ITEMS+=("$file")
            printf 'ERROR: Could not truncate: %s\n' "$file" >&2
        fi
    done < <(sudo find / -xdev -type f -size +100M -print0 2>/dev/null)

    (( count > 0 )) || echo "No qualifying log files found."
}

main() {
    if ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: sudo is required." >&2
        exit 1
    fi

    section "Disk cleanup started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "This script clears only the contents of $DUPLICITY_CACHE and truncates log files over 100 MiB."
    echo "It does not remove any of the reported top directories."
    echo
    echo "Sudo access is required; you may be prompted for your password."
    sudo -v

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
        echo "No files required cleanup."
    fi

    if (( ${#FAILED_ITEMS[@]} > 0 )); then
        printf '\nItems that could not be cleaned:\n' >&2
        printf '%s\n' "${FAILED_ITEMS[@]}" >&2
    fi

    section "Disk usage after cleanup"
    show_disk_usage
    show_top_directories "Top 5 largest root-level directories after cleanup"
    show_top_applications "Top 5 largest application directories after cleanup"

    section "Disk cleanup completed"
}

main "$@"
