#!/bin/bash

# Track Elasticsearch status
es_status=""

echo "-----------------------------------------"
echo "🔄 Restarting Apache..."
sudo systemctl restart apache2 && echo "✅ Apache restarted." || echo "❌ Failed to restart Apache."

echo "-----------------------------------------"
echo "🔄 Restarting Nginx..."
sudo systemctl restart nginx && echo "✅ Nginx restarted." || echo "❌ Failed to restart Nginx."

echo "-----------------------------------------"
echo "🔄 Restarting MySQL..."
sudo systemctl restart mysql && echo "✅ MySQL restarted." || echo "❌ Failed to restart MySQL."

echo "-----------------------------------------"
echo "🧹 Clearing Swap Memory..."
sudo swapoff -a && sudo swapon -a && echo "✅ Swap memory cleared." || echo "❌ Failed to clear swap."

echo "-----------------------------------------"
echo "🔄 Restarting Elasticsearch..."
if sudo systemctl restart elasticsearch; then
  echo "✅ Elasticsearch restarted."
  es_status="✅ Elasticsearch has restarted successfully."
else
  echo "❌ Failed to restart Elasticsearch."
  es_status="❌ Elasticsearch was NOT restarted."
fi

echo "-----------------------------------------"
echo "📊 Current Memory and Swap Usage:"
free -h

echo "-----------------------------------------"
echo "$es_status"
echo "✅ Maintenance completed."
