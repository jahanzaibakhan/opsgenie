#!/usr/bin/env bash
# disk-cleanup-report.sh  (run ON THE PROXY server)
# Connects to each server with "cng <IP>", runs disk-cleanup.sh, and prints a
# before/after disk usage table (also saved as CSV in the current directory).
#
# Usage (curl):
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup-report.sh | bash -s -- servers.txt
#   curl -fsSL https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup-report.sh | bash -s -- 1.2.3.4 5.6.7.8
#   (no arguments = uses ./servers.txt)
#
# Optional env vars (put before "bash"):  PARALLEL=5  MOUNT=/  CONNECT_CMD=cng
#   e.g.  curl -fsSL <url> | PARALLEL=10 bash -s -- servers.txt

# Everything is inside main() so bash reads the whole script before running it
# (required for safe "curl | bash" execution).
main() {
  set -uo pipefail

  local MOUNT="${MOUNT:-/}"
  local PARALLEL="${PARALLEL:-5}"
  CONNECT_CMD="${CONNECT_CMD:-cng}"
  local CLEANUP_URL="https://raw.githubusercontent.com/jahanzaibakhan/opsgenie/main/disk-cleanup.sh"

  # cng is usually an alias/function in ~/.bashrc, which only loads in
  # interactive shells. "curl | bash" is not interactive, so ask an
  # interactive bash for the definition and import it here.
  local name="${CONNECT_CMD%% *}" kind
  if ! type "$name" >/dev/null 2>&1; then
    kind=$(bash -ic "type -t $name" </dev/null 2>/dev/null | tail -1)
    case "$kind" in
      alias)
        shopt -s expand_aliases
        eval "$(bash -ic "alias $name" </dev/null 2>/dev/null | grep "^alias $name=" | tail -1)" ;;
      function)
        eval "$(bash -ic "declare -f $name" </dev/null 2>/dev/null | sed -n "/^$name ()/,\$p")" ;;
      file)
        CONNECT_CMD="$(bash -ic "type -P $name" </dev/null 2>/dev/null | tail -1)${CONNECT_CMD#"$name"}" ;;
    esac
  fi
  if ! type "${CONNECT_CMD%% *}" >/dev/null 2>&1; then
    echo "ERROR: '$name' not found. Run 'type $name' on this server and share the output." >&2
    return 1
  fi
  echo "Using: $(type "${CONNECT_CMD%% *}" 2>/dev/null | head -1)" >&2

  # ---- Server list ----------------------------------------------------------
  [ $# -eq 0 ] && set -- servers.txt
  SERVERS=()
  if [ $# -eq 1 ] && [ -f "$1" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"; line="$(echo "$line" | xargs)"
      [ -n "$line" ] && SERVERS+=("$line")
    done < "$1"
  elif [ $# -eq 1 ] && [ "$1" = "servers.txt" ]; then
    echo "ERROR: servers.txt not found in $(pwd). Create it (one IP per line) or pass IPs as arguments." >&2
    return 1
  else
    SERVERS=("$@")
  fi
  [ ${#SERVERS[@]} -eq 0 ] && { echo "No servers found." >&2; return 1; }

  # ---- Commands sent to each server -----------------------------------------
  REMOTE_SCRIPT="{
M='$MOUNT'; URL='$CLEANUP_URL'
$(cat <<'EOF'
  (set -o pipefail) 2>/dev/null && set -o pipefail
  usage() { df -Pk "$M" | awk 'NR==2 {print $2, $3, $5}'; }   # size_kb used_kb use%
  SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
  echo "BEFORE $(usage)"
  curl -fsSL "$URL" | $SUDO bash > /tmp/disk-cleanup.log 2>&1
  echo "RC $?"
  echo "AFTER $(usage)"
  exit 0
EOF
)
}"

  # ---- Run in parallel ------------------------------------------------------
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  echo "Running cleanup on ${#SERVERS[@]} server(s), $PARALLEL at a time..." >&2
  local i=0 ip
  for ip in "${SERVERS[@]}"; do
    i=$((i + 1))
    run_host "$ip" "$TMP/$(printf '%05d' "$i")" &
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do sleep 1; done
  done
  wait
  echo >&2

  print_report
}

run_host() {
  local ip="$1" out="$2" raw
  # eval so aliases/functions like "cng" work
  raw=$(eval "$CONNECT_CMD \"\$ip\"" <<< "$REMOTE_SCRIPT" 2>/dev/null)
  echo "$raw" | tr -d '\r' | awk -v ip="$ip" '
    /^BEFORE/ {size=$2; ub=$3; pb=$4}
    /^RC/     {crc=$2}
    /^AFTER/  {ua=$3; pa=$4}
    END {
      if (ub == "")          status = "CONNECT FAILED"
      else if (crc != 0)     status = "SCRIPT ERROR (rc=" crc ")"
      else                   status = "OK"
      print ip "|" size "|" ub "|" pb "|" ua "|" pa "|" status
    }' > "$out"
  echo "  done: $ip" >&2
}

print_report() {
  local REPORT="disk-cleanup-$(date +%Y%m%d-%H%M%S).csv"
  cat "$TMP"/* | awk -F'|' -v csv="$REPORT" '
    function h(kb,   s, u, i) {
      if (kb == "") return "-"
      s = ""; if (kb < 0) { s = "-"; kb = -kb }
      split("K M G T", u, " "); i = 1
      while (kb >= 1024 && i < 4) { kb /= 1024; i++ }
      return s sprintf("%.1f%s", kb, u[i])
    }
    function d(v) { return v == "" ? "-" : v }
    BEGIN {
      fmt = "| %-16s | %-9s | %-11s | %-9s | %-11s | %-9s | %-9s | %-22s |\n"
      sep = "+------------------+-----------+-------------+-----------+-------------+-----------+-----------+------------------------+"
      print sep
      printf fmt, "Server IP", "Disk Size", "Used Before", "Use% Bef", "Used After", "Use% Aft", "Freed", "Status"
      print sep
      print "server_ip,disk_size_kb,used_before_kb,use_pct_before,used_after_kb,use_pct_after,freed_kb,status" > csv
    }
    {
      freed = ($3 != "" && $5 != "") ? $3 - $5 : ""
      if (freed != "") total += freed
      if ($7 == "OK") ok++; else bad++
      printf fmt, $1, h($2), h($3), d($4), h($5), d($6), h(freed), $7
      print $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," freed "," $7 > csv
    }
    END {
      print sep
      printf "Servers OK: %d   Failed: %d   Total freed: %s   CSV: %s\n", ok, bad, h(total + 0), csv
    }'
}

main "$@"
