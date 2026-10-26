#!/usr/bin/env bash
#
# Safely reclaim disk space from duplicity cache, leftover backup SQL dumps,
# and oversized log files. Optionally clears oversized application caches
# (WordPress, Magento, Laravel).
# Fast default: curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh | bash
# Full audit:   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh | bash -s -- --full-scan
# App caches:   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh | bash -s -- --clear-app-cache

set -u
set -o pipefail

readonly DUPLICITY_CACHE="/home/.duplicity"
readonly APP_ROOT="/home/master/applications"
# Failed automated backups leave .sql dumps behind in per-application folders.
readonly BACKUP_ROOT="/home/backups"
readonly LOG_LIMIT_BYTES=$((100 * 1024 * 1024))
# An application's cache is cleared only when it is larger than this.
readonly CACHE_LIMIT_BYTES=$((100 * 1024 * 1024))
FULL_SCAN=false
CLEAR_APP_CACHE=false
declare -a CLEANED_ITEMS=()
declare -a FAILED_ITEMS=()
declare -i EXPECTED_RECLAIMED_BYTES=0

usage() {
    cat <<'EOF'
Usage: disk-cleanup.sh [--full-scan] [--clear-app-cache]

Without arguments, the script uses fast mode. It clears the duplicity cache,
removes .sql files left by failed backups anywhere under /home/backups, checks
/var/log, /var/mail, application log directories, framework logs (Magento
var/log, Laravel storage/logs, WordPress wp-content/debug.log), and PM2 log
directories for oversized logs, and reports disk space before and after cleanup.

--full-scan        Include recursive top-directory and application-size reports,
                   and search the entire root filesystem for eligible oversized
                   log files.
--clear-app-cache  Also clear WordPress, Magento, and Laravel caches larger than
                   100 MiB in each application.
EOF
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --full-scan) FULL_SCAN=true ;;
            --clear-app-cache) CLEAR_APP_CACHE=true ;;
            -h|--help) usage; exit 0 ;;
            *)
                error "ERROR: Unknown option: $1"
                usage >&2
                exit 2
                ;;
        esac
        shift
    done
}

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

physical_free_space_bytes() {
    # df's Available column excludes filesystem blocks reserved for root.
    # Size - Used reflects all currently unallocated blocks on the filesystem.
    df -PB1 / 2>/dev/null | awk 'NR == 2 { print $2 - $3 }'
}

show_reclaimed_space() {
    local available_before="$1"
    local available_after="$2"
    local physical_before="$3"
    local physical_after="$4"
    local available_reclaimed=$((available_after - available_before))
    local physical_reclaimed=$((physical_after - physical_before))
    local root_reserved=$((physical_after - available_after))

    if (( physical_reclaimed > 0 )); then
        success "✓ Physical disk space reclaimed on /: $(human_size "$physical_reclaimed")"
    elif (( physical_reclaimed == 0 )); then
        warning "• Physical free space on / did not change."
    else
        warning "• Physical free space on / decreased by $(human_size "$((physical_before - physical_after))") while the script ran."
    fi

    success "✓ Physical free space on /: $(human_size "$physical_after")"
    success "✓ Free space available to non-root users on /: $(human_size "$available_after")"

    if (( root_reserved > 0 )); then
        warning "• $(human_size "$root_reserved") is reserved or otherwise unavailable to non-root users on this filesystem."
        if (( available_reclaimed >= 0 && physical_reclaimed > available_reclaimed )); then
            warning "• The difference between reclaimed and user-available space is due to that reservation."
        fi
    fi
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
    local physical_before="$1"
    local physical_after="$2"
    local observed=$((physical_after - physical_before))

    section "Cleanup space reconciliation"
    echo "Allocated blocks cleared: $(human_size "$EXPECTED_RECLAIMED_BYTES")"
    echo "Observed physical free-space increase: $(human_size "$(( observed > 0 ? observed : 0 ))")"

    if (( observed + (16 * 1024 * 1024) < EXPECTED_RECLAIMED_BYTES )); then
        warning "• The physical free-space increase is lower than the allocated blocks cleared."
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
        # /var/mail: local mailboxes (e.g. root's cron mail) grow without rotation.
        /var/log/*|/var/mail/*|*.log|*.log.[0-9]*|*.log-????????|*.out|*.err)
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

clean_backup_sql_files() {
    section "SQL dump cleanup in $BACKUP_ROOT"
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        warning "• No backup directory found at $BACKUP_ROOT."
        return
    fi

    local file bytes
    local count=0

    echo "Checking all folders in $BACKUP_ROOT for .sql files"
    while IFS= read -r -d '' file; do
        bytes=$(allocated_file_bytes "$file" || echo 0)
        if sudo rm -f -- "$file"; then
            EXPECTED_RECLAIMED_BYTES+=bytes
            CLEANED_ITEMS+=("$file ($(human_size "$bytes") removed)")
            success "✓ Removed: $file ($(human_size "$bytes"))"
            ((count++))
        else
            FAILED_ITEMS+=("$file")
            error "ERROR: Could not remove: $file"
        fi
    done < <(sudo find "$BACKUP_ROOT" -xdev -type f -iname '*.sql' -print0 2>/dev/null)

    (( count > 0 )) || warning "• No qualifying .sql files found."
}

# Run a command as the application's system user, from the given directory, so
# files it creates keep the owner PHP-FPM expects. Cloudways wp-config.php
# files require wp-salt.php by relative path, so WP-CLI must run from the
# docroot. runuser needs root, which sudo provides.
run_as_app_user() {
    local owner="$1"
    local workdir="$2"
    shift 2
    sudo runuser -u "$owner" -- sh -c 'cd "$1" && shift && exec "$@"' sh "$workdir" "$@"
}

paths_size_bytes() {
    local total=0 path bytes
    for path in "$@"; do
        sudo test -d "$path" || continue
        bytes=$(directory_size_bytes "$path" || echo 0)
        total=$((total + ${bytes:-0}))
    done
    echo "$total"
}

# Delete cached files but keep the guard files that caching plugins and
# frameworks place at the top of their cache folders (.htaccess rules, index
# files that block directory listing, .gitignore placeholders). Guards are
# only kept in the first two levels: deeper down, page caches such as WP
# Rocket and WP Super Cache store the cached pages themselves as index.html.
# Empty folders at or below min_dir_depth are removed afterwards so millions
# of empty page-cache folders do not keep consuming inodes and blocks.
clear_cache_files() {
    local dir="$1"
    local min_dir_depth="$2"
    sudo test -d "$dir" || return 0
    sudo find "$dir" -xdev -mindepth 1 -maxdepth 2 -type f \
        ! -name '.htaccess' ! -name 'index.html' ! -name 'index.php' ! -name '.gitignore' \
        -delete 2>/dev/null
    sudo find "$dir" -xdev -mindepth 3 -type f -delete 2>/dev/null
    sudo find "$dir" -xdev -mindepth "$min_dir_depth" -depth -type d -empty -delete 2>/dev/null
    return 0
}

record_cache_cleanup() {
    local label="$1"
    local before="$2"
    local after="$3"
    local freed=$(( before > after ? before - after : 0 ))

    EXPECTED_RECLAIMED_BYTES+=freed
    CLEANED_ITEMS+=("$label ($(human_size "$freed") removed)")
    success "✓ Cleared: $label ($(human_size "$before") → $(human_size "$after"))"
}

# Cached HTML in Varnish can reference minified CSS/JS files that were just
# deleted. Purge the site's Varnish cache the same way Breeze does on
# Cloudways: a PURGE request with the site's Host header purges the domain.
purge_wordpress_varnish() {
    local app_name="$1"
    local owner="$2"
    local docroot="$3"
    local url scheme host port code
    local purged_hosts=""

    pgrep -x varnishd >/dev/null 2>&1 || return 0
    if [[ "$owner" == "root" ]] || ! command -v wp >/dev/null 2>&1; then
        warning "• $app_name: purge Varnish from the Cloudways panel so cached pages do not reference removed assets."
        return 0
    fi

    # --skip-plugins/--skip-themes reads the option without running site code.
    for url in $(run_as_app_user "$owner" "$docroot" timeout 60 wp --path="$docroot" \
            option get home --skip-plugins --skip-themes 2>/dev/null) \
        $(run_as_app_user "$owner" "$docroot" timeout 60 wp --path="$docroot" \
            option get siteurl --skip-plugins --skip-themes 2>/dev/null); do
        [[ "$url" == http://* || "$url" == https://* ]] || continue
        scheme=${url%%://*}
        host=${url#*://}
        host=${host%%/*}
        host=${host%%:*}
        [[ -n "$host" && " $purged_hosts " != *" $host "* ]] || continue
        purged_hosts+=" $host"
        port=80
        [[ "$scheme" == https ]] && port=443
        # --resolve keeps the request local while sending the right Host/SNI.
        code=$(curl -sk -o /dev/null -m 10 -w '%{http_code}' -X PURGE \
            --resolve "$host:$port:127.0.0.1" "$scheme://$host/.*" 2>/dev/null) || code=000
        if [[ "$code" == 200 ]]; then
            success "✓ $app_name: purged Varnish cache for $host"
        else
            warning "• $app_name: Varnish purge for $host returned HTTP $code; purge it from the Cloudways panel."
        fi
    done
    if [[ -z "$purged_hosts" ]]; then
        warning "• $app_name: could not read the site URL; purge Varnish from the Cloudways panel."
    fi
}

clean_wordpress_cache() {
    local app_name="$1"
    local owner="$2"
    local docroot="$3"
    local cache_dir="$docroot/wp-content/cache"
    local before after

    sudo test -d "$cache_dir" || return 1
    before=$(paths_size_bytes "$cache_dir")
    if (( before <= CACHE_LIMIT_BYTES )); then
        echo "• $app_name (WordPress): cache is $(human_size "$before"); below limit."
        return 1
    fi

    # Page caches and minified assets under wp-content/cache are regenerated
    # by the caching plugin on the next request. Object caches in Redis or
    # Memcached, uploads, and plugin settings are not touched. Folders at
    # wp-content/cache/<plugin>/<subfolder> are kept.
    clear_cache_files "$cache_dir" 3
    after=$(paths_size_bytes "$cache_dir")
    record_cache_cleanup "$cache_dir" "$before" "$after"
    purge_wordpress_varnish "$app_name" "$owner" "$docroot"
}

clean_magento_cache() {
    local app_name="$1"
    local docroot="$2"
    local -a cache_dirs=("$docroot/var/cache" "$docroot/var/page_cache")
    local before after

    before=$(paths_size_bytes "${cache_dirs[@]}")
    if (( before <= CACHE_LIMIT_BYTES )); then
        echo "• $app_name (Magento): file cache is $(human_size "$before"); below limit."
        return 1
    fi

    # Only the file-based cache storage is removed, which is what
    # "bin/magento cache:flush" does for the file backend. generated/,
    # pub/static/, var/view_preprocessed/, and sessions are left alone because
    # removing them in production mode requires a redeploy or logs users out.
    # Redis/Varnish are not touched because this targets leftover files only.
    clear_cache_files "${cache_dirs[0]}" 1
    clear_cache_files "${cache_dirs[1]}" 1
    after=$(paths_size_bytes "${cache_dirs[@]}")
    record_cache_cleanup "$docroot/var/{cache,page_cache}" "$before" "$after"
}

clean_laravel_cache() {
    local app_name="$1"
    local owner="$2"
    local docroot="$3"
    local data_dir="$docroot/storage/framework/cache/data"
    local views_dir="$docroot/storage/framework/views"
    local before after expired

    before=$(paths_size_bytes "$data_dir" "$views_dir")
    if (( before <= CACHE_LIMIT_BYTES )); then
        echo "• $app_name (Laravel): cache is $(human_size "$before"); below limit."
        return 1
    fi

    # "php artisan cache:clear" is avoided: on a Redis store it flushes the
    # whole Redis database, which can also hold queued jobs. Sessions and
    # bootstrap/cache are never touched.
    #
    # 1. The file cache store never deletes expired entries on its own. Each
    #    entry starts with a 10-digit expiry timestamp, so remove only those
    #    already expired.
    if [[ "$owner" != "root" ]] && sudo test -d "$data_dir" && command -v php >/dev/null 2>&1; then
        expired=$(run_as_app_user "$owner" "$docroot" timeout 1800 php -r '
            $n = 0; $now = time();
            $it = new RecursiveIteratorIterator(
                new RecursiveDirectoryIterator($argv[1], FilesystemIterator::SKIP_DOTS));
            foreach ($it as $f) {
                if (!$f->isFile() || $f->isLink()) continue;
                $h = @file_get_contents($f->getPathname(), false, null, 0, 10);
                if ($h === false || strlen($h) !== 10 || !ctype_digit($h)) continue;
                if ((int) $h < $now && @unlink($f->getPathname())) $n++;
            }
            echo $n;' -- "$data_dir" 2>/dev/null || echo 0)
        echo "• $app_name (Laravel): removed ${expired:-0} expired file-cache entries."
    fi

    # 2. Compiled Blade views are rebuilt on demand ("php artisan view:clear").
    after=$(paths_size_bytes "$data_dir" "$views_dir")
    if (( after > CACHE_LIMIT_BYTES )) && sudo test -d "$views_dir"; then
        sudo find "$views_dir" -xdev -maxdepth 1 -type f -name '*.php' -delete 2>/dev/null
        after=$(paths_size_bytes "$data_dir" "$views_dir")
    fi

    # 3. Only if still over the limit, clear the remaining file-cache entries.
    if (( after > CACHE_LIMIT_BYTES )); then
        clear_cache_files "$data_dir" 1
        after=$(paths_size_bytes "$data_dir" "$views_dir")
    fi
    record_cache_cleanup "$docroot/storage/framework/{cache/data,views}" "$before" "$after"
}

clean_application_caches() {
    section "Application caches larger than 100 MiB (WordPress, Magento, Laravel)"
    if [[ ! -d "$APP_ROOT" ]]; then
        warning "• Application directory not found: $APP_ROOT"
        return
    fi

    local app_link app_dir app_name docroot owner
    local count=0
    local -A seen=()

    for app_link in "$APP_ROOT"/*; do
        # Some application entries are symlinks to another application.
        app_dir=$(readlink -f -- "$app_link") || continue
        [[ -n "${seen[$app_dir]:-}" ]] && continue
        seen[$app_dir]=1
        docroot="$app_dir/public_html"
        sudo test -d "$docroot" || continue
        app_name=$(basename "$app_dir")
        owner=$(sudo stat -c '%U' -- "$docroot" 2>/dev/null || echo root)

        if sudo test -f "$docroot/bin/magento" && sudo test -f "$docroot/app/etc/env.php"; then
            clean_magento_cache "$app_name" "$docroot" && ((count++))
        elif sudo test -f "$docroot/artisan"; then
            clean_laravel_cache "$app_name" "$owner" "$docroot" && ((count++))
        elif sudo test -f "$docroot/wp-config.php"; then
            clean_wordpress_cache "$app_name" "$owner" "$docroot" && ((count++))
        fi
    done

    (( count > 0 )) || warning "• No application caches above 100 MiB found."
}

truncate_large_logs() {
    section "Log and mailbox files larger than 100 MiB"
    local file apparent_bytes bytes scan_label
    local count=0
    local -a scan_roots=()

    if [[ "$FULL_SCAN" == true ]]; then
        scan_label="Full filesystem scan (current filesystem only)"
        scan_roots=(/)
    else
        # Avoid a recursive walk of every application. Known log directories
        # are checked directly, which keeps the default path fast.
        scan_label="Fast scan: /var/log, /var/mail, application and framework log directories, and PM2 logs"
        scan_roots=(/var/log)
        [[ -d /var/mail ]] && scan_roots+=(/var/mail)
        if [[ -d "$APP_ROOT" ]]; then
            local app_dir log_path
            local -A seen_apps=()
            for app_dir in "$APP_ROOT"/*; do
                # Some application entries are symlinks to another application.
                app_dir=$(readlink -f -- "$app_dir") || continue
                [[ -n "${seen_apps[$app_dir]:-}" ]] && continue
                seen_apps[$app_dir]=1
                # Application folders are not always readable by the SSH
                # user, so existence checks go through sudo. Framework logs
                # live inside the docroot: Magento var/log, Laravel
                # storage/logs, and the WordPress WP_DEBUG log.
                for log_path in "$app_dir/logs" "$app_dir/log" \
                    "$app_dir/public_html/var/log" \
                    "$app_dir/public_html/storage/logs" \
                    "$app_dir/public_html/wp-content/debug.log"; do
                    sudo test -e "$log_path" && scan_roots+=("$log_path")
                done
            done
        fi
        # PM2 stores logs outside app directories, typically under the
        # account home. Glob expansion reads only home-directory entries and
        # does not recursively scan application data.
        for pm2_logs in /home/*/.pm2/logs /root/.pm2/logs; do
            [[ -d "$pm2_logs" ]] && scan_roots+=("$pm2_logs")
        done
    fi

    echo "$scan_label"
    # -xdev prevents mounted backups, network shares, /proc, /sys, and other
    # virtual filesystems from being traversed.
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
    done < <(sudo find "${scan_roots[@]}" -xdev -type f -size +100M -print0 2>/dev/null)

    (( count > 0 )) || warning "• No qualifying log files found."
}

main() {
    parse_arguments "$@"

    if ! command -v sudo >/dev/null 2>&1; then
        error "ERROR: sudo is required."
        exit 1
    fi

    section "Disk cleanup started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    warning "This script clears only the contents of $DUPLICITY_CACHE, removes .sql files from all folders in $BACKUP_ROOT, and truncates log and mailbox files over 100 MiB."
    if [[ "$CLEAR_APP_CACHE" == true ]]; then
        warning "App cache mode is enabled; WordPress, Magento, and Laravel caches over 100 MiB will also be cleared."
    fi
    warning "It does not remove any of the reported top directories."
    if [[ "$FULL_SCAN" == true ]]; then
        warning "Full-scan mode is enabled; recursive disk and application scans may take time."
    else
        success "Fast mode is enabled; use --full-scan for recursive directory and application size reports."
    fi
    echo
    warning "Sudo access is required; you may be prompted for your password."
    sudo -v

    local free_before free_after physical_free_before physical_free_after
    free_before=$(free_space_bytes || echo 0)
    physical_free_before=$(physical_free_space_bytes || echo 0)
    section "Disk usage before cleanup"
    show_disk_usage
    if [[ "$FULL_SCAN" == true ]]; then
        show_top_directories "Top 5 largest root-level directories before cleanup"
        show_top_applications "Top 5 largest application directories before cleanup"
    fi

    clean_duplicity_cache
    clean_backup_sql_files
    [[ "$CLEAR_APP_CACHE" == true ]] && clean_application_caches
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
    physical_free_after=$(physical_free_space_bytes || echo 0)
    show_reclaimed_space "$free_before" "$free_after" "$physical_free_before" "$physical_free_after"
    show_cleanup_reconciliation "$physical_free_before" "$physical_free_after"
    if [[ "$FULL_SCAN" == true ]]; then
        show_top_directories "Top 5 largest root-level directories after cleanup"
        show_top_applications "Top 5 largest application directories after cleanup"
    fi

    section "Disk cleanup completed"
}

main "$@"
