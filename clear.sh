#!/bin/bash

# Function to restart a service
restart_service() {
    SERVICE_NAME=$1
    echo "Restarting $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME"
    if [ $? -eq 0 ]; then
        echo "$SERVICE_NAME restarted successfully."
    else
        echo "Failed to restart $SERVICE_NAME."
    fi
    echo "--------------------------------------------"
}

# List of services
SERVICES=("apache2" "nginx" "varnish" "mysql" "redis")

# Restart base services
for service in "${SERVICES[@]}"; do
    restart_service "$service"
done

# Detect and restart PHP-FPM
PHP_FPM=$(systemctl list-units --type=service --no-pager | grep -oP 'php[\d\.]+-fpm(?=\.service)' | head -n 1)
if [ -n "$PHP_FPM" ]; then
    echo "Detected PHP-FPM service: $PHP_FPM"
    restart_service "$PHP_FPM"
else
    echo "No PHP-FPM service detected!"
fi

# Clear swap
echo "Clearing swap memory..."
sudo swapoff -a && sudo swapon -a
echo "Swap memory cleared."
echo "--------------------------------------------"

# Done
echo "✅ All services have been restarted successfully!"
