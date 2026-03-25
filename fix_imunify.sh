#!/bin/bash

# Define the lock file path
LOCK_FILE="/var/lib/rpm-state/imunify360-transaction-in-progress"

echo "------------------------------------------------"
echo "🔍 STEP 1: Checking Imunify360 Health Status..."
echo "------------------------------------------------"

# Check if the lock file exists
if [ -f "$LOCK_FILE" ]; then
    echo "⚠️  ISSUE DETECTED: A stalled update lock was found."
    echo "Location: $LOCK_FILE"
    echo "Impact: This file prevents the Imunify360 service from starting."
    echo ""
    
    # Ask the user for permission to fix
    read -p "Do you want to fix this issue now? (Y/N): " confirm
    if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
        
        echo "------------------------------------------------"
        echo "🛠️  STEP 2: Starting Repair Process..."
        
        # 1. Remove the lock file
        echo "⏳ Task 1/4: Removing the transaction lock file..."
        sudo rm "$LOCK_FILE"
        echo "✅ Task 1/4: Completed."

        # 2. Repair package manager
        echo "⏳ Task 2/4: Repairing interrupted package configurations..."
        sudo dpkg --configure -a
        echo "✅ Task 2/4: Completed."

        # 3. Reload systemd
        echo "⏳ Task 3/4: Reloading system service manager..."
        sudo systemctl daemon-reload
        echo "✅ Task 3/4: Completed."

        # 4. Start the service
        echo "⏳ Task 4/4: Attempting to start Imunify360..."
        sudo systemctl start imunify360
        echo "✅ Task 4/4: Completed."

        echo "------------------------------------------------"
        echo "📊 FINAL RESULT: Service Status"
        echo "------------------------------------------------"
        sudo systemctl status imunify360 --no-pager
        
    else
        echo "❌ Operation cancelled by user. No changes were made."
    fi
else
    echo "✨ NO ISSUES FOUND: The update lock file does not exist."
    echo "Service Status:"
    sudo systemctl is-active imunify360
fi
