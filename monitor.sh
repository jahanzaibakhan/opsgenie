#!/bin/bash
echo "==== SYSTEM LOAD ===="
uptime
echo "==== TOP PROCESSES ===="
ps -eo pid,ppid,user,cmd,%cpu,%mem --sort=-%cpu | head -20
echo "==== DISK I/O ===="
iostat -xz 1 2
echo "==== NETWORK CONNECTIONS (Send-Q > 0) ===="
ss -tn state established | awk 'NR>1 && $2>0 {print $0}' | head -20
echo "==== MYSQL PROCESSLIST ===="
mysql -e "SHOW FULL PROCESSLIST;"
