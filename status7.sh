#!/bin/bash

# Server Health Check Script
# Usage: 
#   bash check.sh 64.176.172.223
#   curl -s https://raw.githubusercontent.com/user/repo/status.sh | bash -s 64.176.172.223

SERVER_IP="$1"

if [ -z "$SERVER_IP" ]; then
    echo "Usage: bash check.sh <SERVER_IP>"
    echo "Example: bash check.sh 64.176.172.223"
    exit 1
fi

echo "=========================================="
echo "Server: $SERVER_IP"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""

# Use ssh to connect and run commands
ssh -o StrictHostKeyChecking=no root@"$SERVER_IP" << 'REMOTEEOF'
#!/bin/bash

echo "========== SYSTEM UPTIME =========="
uptime
echo ""

echo "========== MYSQL =========="
if systemctl is-active --quiet mysql 2>/dev/null; then
    echo "✓ MySQL is RUNNING"
    mysql -e "SELECT VERSION();" 2>/dev/null | tail -1
elif systemctl is-active --quiet mariadb 2>/dev/null; then
    echo "✓ MariaDB is RUNNING"
    mysql -e "SELECT VERSION();" 2>/dev/null | tail -1
else
    echo "✗ MySQL/MariaDB is STOPPED"
fi
echo ""

echo "========== APACHE =========="
if systemctl is-active --quiet apache2 2>/dev/null; then
    echo "✓ Apache is RUNNING"
    apachectl -v 2>/dev/null | grep "Server version" | head -1
elif systemctl is-active --quiet httpd 2>/dev/null; then
    echo "✓ Apache (httpd) is RUNNING"
    apachectl -v 2>/dev/null | grep "Server version" | head -1
else
    echo "✗ Apache is STOPPED"
fi
echo ""

echo "========== NGINX =========="
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "✓ Nginx is RUNNING"
    nginx -v 2>&1
else
    echo "✗ Nginx is STOPPED"
fi
echo ""

echo "========== ELASTICSEARCH =========="
if curl -s http://localhost:9200/_cluster/health &> /dev/null; then
    echo "✓ ElasticSearch is RUNNING"
    curl -s http://localhost:9200/ 2>/dev/null | grep -o '"number":"[^"]*"' | head -1
else
    echo "✗ ElasticSearch is STOPPED"
fi
echo ""

echo "========== REDIS =========="
if redis-cli ping &> /dev/null 2>&1; then
    echo "✓ Redis is RUNNING"
    redis-cli info server 2>/dev/null | grep redis_version
else
    echo "✗ Redis is STOPPED"
fi
echo ""

echo "========== MEMORY =========="
free -h
echo ""

echo "========== DISK =========="
df -h /
echo ""

echo "========== CPU =========="
top -bn1 | grep "Cpu(s)"
echo ""

echo "========== COMPLETED =========="
REMOTEEOF
