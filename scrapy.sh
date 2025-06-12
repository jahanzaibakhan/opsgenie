#!/bin/bash

CONF_FILE="/etc/nginx/additional_server_conf"
BLOCK_RULE='if ($http_user_agent ~* "Scrapy") {
    return 403;
}'

# Check if Scrapy block already exists
if grep -q 'Scrapy' "$CONF_FILE"; then
    echo "Scrapy bot block already exists in $CONF_FILE. No changes made."
else
    echo "" >> "$CONF_FILE"
    echo "# Block Scrapy bot" >> "$CONF_FILE"
    echo "$BLOCK_RULE" >> "$CONF_FILE"
    echo "✅ Scrapy bot is now blocked in $CONF_FILE."
fi

# Test Nginx config
echo "🔍 Testing Nginx configuration..."
if nginx -t; then
    echo "✅ Nginx configuration is OK."

    # Reload Nginx
    echo "🔄 Reloading Nginx..."
    systemctl reload nginx
    echo "✅ Nginx is reloaded."
    echo "🎉 Bot blocking is completed successfully."
else
    echo "❌ Nginx configuration test failed. Please check the config file."
fi
