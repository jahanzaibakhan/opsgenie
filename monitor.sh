#!/bin/bash

# Duration to monitor (seconds)
DURATION=10
INTERVAL=2
ITERATIONS=$((DURATION / INTERVAL))

# Arrays to collect metrics
declare -a CPU_USAGE
declare -a MEM_USAGE
declare -a DISK_IO
declare -a CONN_SUM
declare -a MYSQL_CONN

echo "==== Starting server monitoring ===="
echo "Duration: $DURATION seconds, Interval: $INTERVAL seconds"
echo "==================================="

for ((i=1;i<=ITERATIONS;i++)); do
    echo -e "\n=== Snapshot $(date) ==="

    # CPU and Memory top processes
    TOP_OUTPUT=$(ps -eo pid,ppid,user,cmd,%cpu,%mem --sort=-%cpu | head -10)
    echo -e "\nTop CPU/Memory processes:"
    echo "$TOP_OUTPUT"

    CPU=$(ps -eo %cpu --no-headers | awk '{sum+=$1} END {print sum}')
    MEM=$(ps -eo %mem --no-headers | awk '{sum+=$1} END {print sum}')
    CPU_USAGE+=($CPU)
    MEM_USAGE+=($MEM)

    # Disk I/O
    IOSTAT_OUTPUT=$(iostat -xz 1 2 | tail -n 10)
    echo -e "\nDisk I/O:"
    echo "$IOSTAT_OUTPUT"
    DISK_IO+=($(iostat -xz 1 2 | awk '/Device/ {getline; print $14}')) # %util of first device

    # Network connections (Send-Q > 0)
    CONN=$(ss -tn state established | awk 'NR>1 && $2>0 {count++} END{print count}')
    echo -e "\nTCP connections with Send-Q>0: $CONN"
    CONN_SUM+=($CONN)

   # MySQL connections
MYSQL_COUNT=$(mysql -e "SHOW FULL PROCESSLIST;" | wc -l)
echo -e "\nMySQL active connections: $MYSQL_COUNT"
MYSQL_CONN+=($MYSQL_COUNT)

# === Network connections with Send-Q > 0 (detailed) ===
echo -e "\nTCP connections with Send-Q>0 (IP:Port Send-Q):"
ss -tn state established | awk 'NR>1 && $2>0 {print $5, $2}' | cut -d: -f1,2 | sort | uniq -c | sort -nr | tee /tmp/network_sendq_snapshot.txt

# Save number of connections for summary
CONN=$(wc -l < /tmp/network_sendq_snapshot.txt)
CONN_SUM+=($CONN)

sleep $INTERVAL
done

# === Summary / Conclusive report ===
echo -e "\n\n==== MONITORING SUMMARY ===="
echo "Snapshots taken: $ITERATIONS"
echo "Average CPU usage across snapshots: $(awk '{sum+=$1} END {print sum/NR}' <<< "${CPU_USAGE[*]}")%"
echo "Average Memory usage across snapshots: $(awk '{sum+=$1} END {print sum/NR}' <<< "${MEM_USAGE[*]}")%"
echo "Max disk %util observed: $(printf "%s\n" "${DISK_IO[@]}" | sort -nr | head -1)%"
echo "Max TCP connections with Send-Q>0: $(printf "%s\n" "${CONN_SUM[@]}" | sort -nr | head -1)"
echo "Max MySQL active connections: $(printf "%s\n" "${MYSQL_CONN[@]}" | sort -nr | head -1)"

# Conclusive recommendation
echo -e "\n=== CONCLUSION / RECOMMENDATIONS ==="
echo "- If TCP Send-Q is high and persistent, it may indicate DDoS or slow clients."
echo "- High disk %util indicates potential I/O bottleneck (backups, logs, heavy queries)."
echo "- Max CPU and Memory snapshots indicate peak load; check top processes above."
echo "- MySQL max connections indicate DB stress; optimize queries or connections if needed."
echo "- Customer can use this snapshot to understand server behavior and identify potential scaling or security actions."
