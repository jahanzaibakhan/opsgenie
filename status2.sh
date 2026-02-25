#!/bin/bash

################################################################################
# Remote Server Health Check Script
# 
# This script connects to a remote server via SSH (same as: ssh root@IP)
# and shows: Uptime, MySQL, Apache, Nginx, ElasticSearch, Redis status
# 
# Usage:
#   bash check.sh 192.168.1.100
#   bash check.sh root@192.168.1.100
#   curl -s https://raw.github.com/user/repo/check.sh | bash -s 192.168.1.100
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get server IP from command line
SERVER="$1"

# Validate input
if [ -z "$SERVER" ]; then
    echo -e "${RED}Error: Server IP/address required${NC}"
    echo ""
    echo "Usage: bash check.sh <SERVER_IP>"
    echo "Examples:"
    echo "  bash check.sh 192.168.1.100"
    echo "  bash check.sh root@192.168.1.100"
    echo "  bash check.sh ubuntu@192.168.1.100"
    exit 1
fi

# If only IP provided, use root as default user
if [[ ! "$SERVER" =~ @ ]]; then
    SERVER="root@$SERVER"
fi

# Function to print section headers
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Main health check - all commands sent in one SSH connection
print_header "Remote Server Health Check"
echo "Connecting to: $SERVER"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"

# Send all commands in a single SSH connection
ssh "$SERVER" << 'SSHEOF'

# Colors for remote output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# System Uptime
print_header "System Uptime"
uptime

# MySQL Status
print_header "MySQL Status"
if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
    echo -e "${GREEN}✓ MySQL: RUNNING${NC}"
    mysql -e "SELECT VERSION();" 2>/dev/null | tail -1
else
    echo -e "${RED}✗ MySQL: STOPPED${NC}"
fi

# Apache Status
print_header "Apache Status"
if systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
    echo -e "${GREEN}✓ Apache: RUNNING${NC}"
    apachectl -v 2>/dev/null | grep "Server version" | head -1
else
    echo -e "${RED}✗ Apache: STOPPED${NC}"
fi

# Nginx Status
print_header "Nginx Status"
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo -e "${GREEN}✓ Nginx: RUNNING${NC}"
    nginx -v 2>&1
else
    echo -e "${RED}✗ Nginx: STOPPED${NC}"
fi

# ElasticSearch Status
print_header "ElasticSearch Status"
if curl -s http://localhost:9200/_cluster/health &> /dev/null; then
    echo -e "${GREEN}✓ ElasticSearch: RUNNING${NC}"
    echo "Cluster Status:"
    curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -o '"status":"[^"]*"' | sed 's/^/  /'
else
    echo -e "${RED}✗ ElasticSearch: STOPPED${NC}"
fi

# Redis Status
print_header "Redis Status"
if redis-cli ping &> /dev/null 2>&1; then
    echo -e "${GREEN}✓ Redis: RUNNING${NC}"
    echo "Server Info:"
    redis-cli info server 2>/dev/null | grep -E 'redis_version|uptime_in_seconds' | sed 's/^/  /'
else
    echo -e "${RED}✗ Redis: STOPPED${NC}"
fi

# System Resources
print_header "System Resources"
echo "CPU Usage:"
top -bn1 | grep "Cpu(s)" | awk '{print "  User: " $2 ", System: " $4 ", Idle: " $8}'

echo ""
echo "Memory Usage:"
free -h | awk 'NR==2{printf "  Total: %s, Used: %s, Free: %s, Usage: %.2f%%\n", $2, $3, $4, ($3/$2)*100}'

echo ""
echo "Disk Usage:"
df -h / | awk 'NR==2{printf "  Total: %s, Used: %s, Free: %s, Usage: %s\n", $2, $3, $4, $5}'

print_header "Health Check Complete"
echo -e "${GREEN}✓ Report generated at $(date '+%Y-%m-%d %H:%M:%S')${NC}"

SSHEOF

# Check if SSH command was successful
if [ $? -eq 0 ]; then
    echo ""
else
    echo -e "\n${RED}Error: Failed to connect to $SERVER${NC}"
    exit 1
fi
