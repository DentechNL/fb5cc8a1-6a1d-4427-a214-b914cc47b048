#!/bin/bash

### Zabbix Agent Installer (Ubuntu 24.04)
### Author: Jelle Hendrikx (generated with Copilot)

# --- Parameter of interactieve invoer ---
if [ -n "$1" ]; then
    ZBX_SERVER="$1"
else
    read -p "Fill in the IP-address of the Zabbix server (or proxy): " ZBX_SERVER
fi

echo "Zabbix server IP: $ZBX_SERVER"
sleep 1

# --- Root check ---
if [ "$EUID" -ne 0 ]; then
    echo "Use: sudo ./install-zabbix.sh"
    exit 1
fi

# --- Install Zabbix repository ---
echo "==> Installeren Zabbix repository..."
wget https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.4+ubuntu24.04_all.deb -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
apt update -y

# --- Install Zabbix Agent 2 + plugins ---
echo "==> Installeren Zabbix agent 2 + plugins..."
apt install -y zabbix-agent2 zabbix-agent2-plugin-mongodb zabbix-agent2-plugin-mssql zabbix-agent2-plugin-postgresql

# --- Configure Zabbix Agent 2 ---
echo "==> Configuring Zabbix Agent 2..."

sed -i "s/^Server=.*/Server=$ZBX_SERVER/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^ServerActive=.*/ServerActive=$ZBX_SERVER/" /etc/zabbix/zabbix_agent2.conf
sed -i "s/^Hostname=.*/Hostname=$(hostname)/" /etc/zabbix/zabbix_agent2.conf

# --- Restart + enable ---
echo "==> Starting and activating Zabbix Agent 2..."
systemctl restart zabbix-agent2
systemctl enable zabbix-agent2

echo ""
echo "✅ Installation complete!"
echo "✅ Zabbix Agent 2 running and listening to server: $ZBX_SERVER"
echo ""