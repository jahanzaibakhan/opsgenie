#!/bin/bash

################################################################################
# Remote Server Health Check Script
# 
# Usage Examples:
#   bash check.sh 192.168.1.100
#   bash check.sh 192.168.1.100 --user ubuntu --port 2222
#   curl https://raw.github.com/user/repo/check.sh | bash -s 192.168.1.100
#   ./check.sh 192.168.1.100 --key /path/to/key.pem
# 
# This script connects to a remote server via SSH and checks the status of:
# - System uptime
# - MySQL
# - Apache
# - Nginx
# - ElasticSearch
# - Redis
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default Configuration
SERVER_HOST=""
SERVER_USER="root"
SERVER_PORT="22"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            SERVER_USER="$2"
            shift 2
            ;;
        --port)
            SERVER_PORT="$2"
            shift 2
            ;;
        --help)
            echo "Usage: bash check.sh <SERVER_IP> [OPTIONS]"
            echo ""
            echo "Arguments:"
            echo "  <SERVER_IP>      IP address or hostname of the server"
            echo ""
            echo "Options:"
            echo "  --user USER      SSH username (default: root)"
            echo "  --port PORT      SSH port (default: 22)"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  bash check.sh 192.168.1.100"
            echo "  bash check.sh 192.168.1.100 --user ubuntu --port 2222"
            echo "  curl https://raw.github.com/user/repo/check.sh | bash -s 192.168.1.100"
            exit 0
            ;;
        *)
            if [ -z "$SERVER_HOST" ]; then
                SERVER_HOST="$1"
            fi
            shift
            ;;
    esac
done

# Validate that server IP/hostname was provided
if [ -z "$SERVER_HOST" ]; then
    echo -e "${RED}Error: Server IP/hostname is required${NC}"
    echo ""
    echo "Usage: bash check.sh <SERVER_IP> [OPTIONS]"
    echo "Example: bash check.sh 192.168.1.100"
    echo "Example: bash check.sh 192.168.1.100 --user ubuntu --port 2222"
    echo ""
    echo "Run 'bash check.sh --help' for more information"
    exit 1
fi

# Function to print section headers
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Function to check status (online/offline)
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ RUNNING${NC}"
        return 0
    else
        echo -e "${RED}✗ STOPPED${NC}"
        return 1
    fi
}

# Function to execute commands on remote server
execute_remote() {
    ssh -p "${SERVER_PORT}" "${SERVER_USER}@${SERVER_HOST}" "$@"
}

# Main status check function
run_health_check() {
    print_header "Remote Server Health Check"
    echo "Server: ${SERVER_HOST}"
    echo "User: ${SERVER_USER}"
    echo "Port: ${SERVER_PORT}"
    echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Test SSH connection
    print_header "Testing Connection"
    if execute_remote "echo 'Connected successfully'" &> /dev/null; then
        echo -e "${GREEN}✓ SSH connection established${NC}"
    else
        echo -e "${RED}✗ Failed to connect to server${NC}"
        echo "Please check:"
        echo "  - Server IP/hostname is correct: ${SERVER_HOST}"
        echo "  - SSH port is correct: ${SERVER_PORT}"
        echo "  - Username is correct: ${SERVER_USER}"
        echo "  - You have network access to the server"
        exit 1
    fi
    
    # System Uptime
    print_header "System Uptime"
    execute_remote "uptime"
    
    # MySQL Status
    print_header "MySQL Status"
    execute_remote "
    if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
        echo -n 'MySQL Service: '
        echo '✓ RUNNING'
        mysql -e 'SELECT VERSION();' 2>/dev/null | tail -1
    else
        echo -n 'MySQL Service: '
        echo '✗ STOPPED'
    fi
    "
    
    # Apache Status
    print_header "Apache Status"
    execute_remote "
    if systemctl is-active --quiet apache2 2>/dev/null || systemctl is-active --quiet httpd 2>/dev/null; then
        echo -n 'Apache Service: '
        echo '✓ RUNNING'
        apachectl -v 2>/dev/null | grep 'Server version' | head -1
    else
        echo -n 'Apache Service: '
        echo '✗ STOPPED'
    fi
    "
    
    # Nginx Status
    print_header "Nginx Status"
    execute_remote "
    if systemctl is-active --quiet nginx; then
        echo -n 'Nginx Service: '
        echo '✓ RUNNING'
        nginx -v 2>&1
    else
        echo -n 'Nginx Service: '
        echo '✗ STOPPED'
    fi
    "
    
    # ElasticSearch Status
    print_header "ElasticSearch Status"
    execute_remote "
    if curl -s http://localhost:9200/_cluster/health &> /dev/null; then
        echo -n 'ElasticSearch Service: '
        echo '✓ RUNNING'
        echo 'Cluster Status:'
        curl -s http://localhost:9200/_cluster/health 2>/dev/null | grep -o '\"status\":\"[^\"]*\"' | head -1 | sed 's/^/  /'
    else
        echo -n 'ElasticSearch Service: '
        echo '✗ STOPPED'
    fi
    "
    
    # Redis Status
    print_header "Redis Status"
    execute_remote "
    if redis-cli ping &> /dev/null 2>&1; then
        echo -n 'Redis Service: '
        echo '✓ RUNNING'
        echo 'Server Info:'
        redis-cli info server 2>/dev/null | grep -E 'redis_version|uptime_in_seconds' | sed 's/^/  /'
    else
        echo -n 'Redis Service: '
        echo '✗ STOPPED'
    fi
    "
    
    # System Resources
    print_header "System Resources"
    execute_remote "
    echo 'CPU Usage:'
    top -bn1 | grep 'Cpu(s)' | awk '{print \"  User: \" \$2 \", System: \" \$4 \", Idle: \" \$8}'
    
    echo ''
    echo 'Memory Usage:'
    free -h | awk 'NR==2{printf \"  Total: %s, Used: %s, Free: %s, Usage: %.2f%%\n\", \$2, \$3, \$4, (\$3/\$2)*100}'
    
    echo ''
    echo 'Disk Usage:'
    df -h / | awk 'NR==2{printf \"  Total: %s, Used: %s, Free: %s, Usage: %s\n\", \$2, \$3, \$4, \$5}'
    "
    
    print_header "Health Check Complete"
    echo -e "${GREEN}✓ Report generated at $(date '+%Y-%m-%d %H:%M:%S')${NC}\n"
}

# Run the health check
run_health_check
