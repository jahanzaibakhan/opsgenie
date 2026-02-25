#!/bin/bash

# Server Health Check Script
# Usage: bash check.sh 10.0.0.50
# This script uses 'cng' to connect to servers and check their service status

SERVER_IP="$1"

if [ -z "$SERVER_IP" ]; then
    echo "Usage: bash check.sh <SERVER_IP>"
    echo "Example: bash check.sh 10.0.0.50"
    exit 1
fi

echo "=========================================="
echo "Server: $SERVER_IP"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""

echo "========== SYSTEM UPTIME =========="
cng $SERVER_IP "uptime"
echo ""

echo "========== MYSQL =========="
cng $SERVER_IP "systemctl is-active mysql && echo '✓ MySQL is RUNNING' || echo '✗ MySQL is STOPPED'"
echo ""

echo "========== APACHE =========="
cng $SERVER_IP "systemctl is-active apache2 && echo '✓ Apache is RUNNING' || echo '✗ Apache is STOPPED'"
echo ""

echo "========== NGINX =========="
cng $SERVER_IP "systemctl is-active nginx && echo '✓ Nginx is RUNNING' || echo '✗ Nginx is STOPPED'"
echo ""

echo "========== ELASTICSEARCH =========="
cng $SERVER_IP "curl -s http://localhost:9200/_cluster/health &> /dev/null && echo '✓ ElasticSearch is RUNNING' || echo '✗ ElasticSearch is STOPPED'"
echo ""

echo "========== REDIS =========="
cng $SERVER_IP "redis-cli ping &> /dev/null && echo '✓ Redis is RUNNING' || echo '✗ Redis is STOPPED'"
echo ""

echo "========== MEMORY =========="
cng $SERVER_IP "free -h"
echo ""

echo "========== DISK =========="
cng $SERVER_IP "df -h /"
echo ""

echo "========== CPU =========="
cng $SERVER_IP "top -bn1 | grep 'Cpu(s)'"
echo ""

echo "========== COMPLETED =========="
