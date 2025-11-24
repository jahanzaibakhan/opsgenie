#!/bin/bash

# ==============================
# CONFIGURATION
# ==============================
SRC_DIR="/var/log/atop"
DEST_USER="credserver"
DEST_PASS="6Y6k9Bqa"
DEST_IP="157.245.109.69"
DEST_PATH="/home/master/applications/dfqgndmrhc/public_html"

# ==============================
# FUNCTIONS
# ==============================
log() {
    echo -e "\n======== $1 ========\n"
}

# Check OS for package manager
install_sshpass() {
    log "Checking if sshpass is installed..."
    if ! command -v sshpass >/dev/null 2>&1; then
        log "sshpass not found. Installing..."
        if [ -f /etc/debian_version ]; then
            sudo apt update -y
            sudo apt install sshpass -y
        elif [ -f /etc/redhat-release ]; then
            sudo yum install epel-release -y
            sudo yum install sshpass -y
        else
            echo "Unsupported OS. Please install sshpass manually."
            exit 1
        fi
        log "sshpass installed successfully."
    else
        log "sshpass is already installed."
    fi
}

uninstall_sshpass() {
    log "Uninstalling sshpass..."
    if [ -f /etc/debian_version ]; then
        sudo apt remove sshpass -y
    elif [ -f /etc/redhat-release ]; then
        sudo yum remove sshpass -y
    fi
    log "sshpass uninstalled successfully."
}

# ==============================
# MAIN PROCESS
# ==============================
install_sshpass

# 1. Fetch source server IP
log "Fetching Source Server IP"
SOURCE_IP=$(curl -s ifconfig.me)
[ -z "$SOURCE_IP" ] && SOURCE_IP=$(curl -s ipinfo.io/ip)
[ -z "$SOURCE_IP" ] && SOURCE_IP=$(hostname -I | awk '{print $1}')

if [ -z "$SOURCE_IP" ]; then
    echo "Error: Unable to fetch public IP."
    uninstall_sshpass
    exit 1
fi
echo "Source Server IP: $SOURCE_IP"

# 2. Create destination folder
log "Connecting to destination server and creating directory $SOURCE_IP"
sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no $DEST_USER@$DEST_IP "mkdir -p $DEST_PATH/$SOURCE_IP"

if [ $? -ne 0 ]; then
    echo "Error: Unable to connect or create directory on destination server."
    uninstall_sshpass
    exit 1
fi
log "Destination folder created successfully."

# 3. Transfer files
log "Transferring ATOP files from $SRC_DIR to $DEST_PATH/$SOURCE_IP"
sshpass -p "$DEST_PASS" rsync -avz -e "ssh -o StrictHostKeyChecking=no" $SRC_DIR/ $DEST_USER@$DEST_IP:$DEST_PATH/$SOURCE_IP/

if [ $? -ne 0 ]; then
    echo "Error: File transfer failed."
    uninstall_sshpass
    exit 1
fi

log "Files transfer completed successfully!"

# 4. Uninstall sshpass
uninstall_sshpass

log "All tasks completed successfully!"
