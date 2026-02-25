#!/bin/bash

# Simple Server Health Check Script
# Usage: bash check.sh 192.168.1.100

SERVER="$1"

if [ -z "$SERVER" ]; then
    echo "Usage: bash check.sh <SERVER_IP>"
    echo "Example: bash check.sh 192.168.1.100"
    exit 1
fi

# Add root@ if not already there
if [[ ! "$SERVER" =~ @ ]]; then
    SERVER="root@$SERVER"
fi

echo "=========================================="
echo "Connecting to: $SERVER"
echo "=========================================="
echo ""

# Create a temporary script file
TMPFILE="/tmp/health_check_$RANDOM.sh"

cat > "$TMPFILE" << 'EOF'
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
    echo "✓ Apache is RUNNING"
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
    curl -s http://localhost:9200/ 2>/dev/null | grep -o '"version"[^}]*' | head -1
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

echo "========== SYSTEM RESOURCES =========="
echo "CPU Usage:"
top -bn1 | grep "Cpu(s)" | sed 's/^/  /'
echo ""

echo "Memory Usage:"
free -h | sed 's/^/  /'
echo ""

echo "Disk Usage:"
df -h / | sed 's/^/  /'
echo ""

echo "========== COMPLETED =========="
EOF

# Execute the script on remote server
ssh "$SERVER" bash -s < "$TMPFILE"

# Clean up
rm -f "$TMPFILE"
