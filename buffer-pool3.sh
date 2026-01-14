#!/bin/bash

# ===============================
# Colors
# ===============================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}==============================================${NC}"
echo -e "${BOLD}🛠️  MySQL InnoDB Buffer Pool Optimizer${NC}"
echo -e "${BOLD}==============================================${NC}\n"

# ===============================
# Step 1: Detect total RAM
# ===============================
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
if [[ -z "$TOTAL_RAM_MB" ]]; then
    echo -e "${RED}❌ Unable to detect server RAM${NC}"
    exit 1
fi

IDEAL_BP_MB=$(( TOTAL_RAM_MB * 40 / 100 ))

echo -e "${BOLD}🧠 Step 1: Server Memory${NC}"
echo -e "Total RAM      : ${GREEN}${TOTAL_RAM_MB} MB${NC}"
echo -e "Ideal BP (40%) : ${GREEN}${IDEAL_BP_MB} MB${NC}"

# ===============================
# Step 2: Get current buffer pool size
# ===============================
CURRENT_BP_BYTES=$(mysql -Nse "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" 2>/dev/null | awk '{print $2}')
CURRENT_BP_MB=$(( CURRENT_BP_BYTES / 1024 / 1024 ))

echo -e "\n${BOLD}🗄️ Step 2: Current MySQL Buffer Pool${NC}"
echo -e "Current Buffer Pool Size: ${YELLOW}${CURRENT_BP_MB} MB${NC}"

# ===============================
# Step 3: CPU & Memory Status
# ===============================
echo -e "\n${BOLD}📊 Step 3: CPU & Memory Status${NC}"
CPU_USAGE=$(top -bn1 | awk -F',' '/Cpu/ {print 100 - $4}' | awk '{printf "%.0f\n",$1}')
echo -e "CPU Usage : ${YELLOW}${CPU_USAGE}%${NC}"

echo -e "\nMemory Usage:"
free -h

# ===============================
# Step 4: Determine if change is needed
# ===============================
echo -e "\n${BOLD}📝 Step 4: Recommendation${NC}"

DIFF=$(( IDEAL_BP_MB - CURRENT_BP_MB ))
ABS_DIFF=${DIFF#-}

if (( ABS_DIFF <= 10 )); then
    echo -e "${GREEN}${BOLD}✅ Buffer pool is already optimal${NC}"
    exit 0
elif (( CURRENT_BP_MB < IDEAL_BP_MB )); then
    echo -e "${YELLOW}${BOLD}ℹ️ Buffer pool can be safely increased${NC}"
    NEEDS_CHANGE=true
else
    echo -e "${RED}${BOLD}⚠️ Buffer pool is over-allocated${NC}"
    NEEDS_CHANGE=true
fi

echo -e "Recommended Buffer Pool Size: ${GREEN}${IDEAL_BP_MB} MB${NC}"

# ===============================
# Step 5: Ask for confirmation (works via GitHub pipe)
# ===============================
read -rp "$(echo -e ${BOLD}Apply this change? [Y/N]:${NC} )" CONFIRM < /dev/tty

if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}⚠️ No changes applied. Exiting.${NC}"
    exit 0
fi

# ===============================
# Step 6: Apply configuration
# ===============================
MYSQL_CONF="/etc/mysql/conf.d/custom.cnf"
BACKUP_CONF="${MYSQL_CONF}.bak.$(date +%F_%T)"

if [[ ! -f "$MYSQL_CONF" ]]; then
    echo -e "${RED}❌ MySQL config file not found${NC}"
    exit 1
fi

cp "$MYSQL_CONF" "$BACKUP_CONF"
echo -e "${GREEN}✔ Backup created: $BACKUP_CONF${NC}"

if grep -q "^innodb_buffer_pool_size" "$MYSQL_CONF"; then
    sed -i "s/^innodb_buffer_pool_size.*/innodb_buffer_pool_size = ${IDEAL_BP_MB}M/" "$MYSQL_CONF"
else
    echo "innodb_buffer_pool_size = ${IDEAL_BP_MB}M" >> "$MYSQL_CONF"
fi
echo -e "${GREEN}✔ Configuration updated${NC}"

# ===============================
# Step 7: Restart MySQL
# ===============================
echo -e "\n${BOLD}🔄 Restarting MySQL...${NC}"
systemctl restart mysql
sleep 3

NEW_BP_BYTES=$(mysql -Nse "SHOW VARIABLES LIKE 'innodb_buffer_pool_size';" | awk '{print $2}')
NEW_BP_MB=$(( NEW_BP_BYTES / 1024 / 1024 ))

echo -e "${GREEN}✅ New Buffer Pool Size: ${NEW_BP_MB} MB${NC}"
echo -e "${BOLD}==============================================${NC}"
echo -e "${GREEN}${BOLD}✔ Optimization Completed Successfully${NC}"
echo -e "${BOLD}==============================================${NC}"
