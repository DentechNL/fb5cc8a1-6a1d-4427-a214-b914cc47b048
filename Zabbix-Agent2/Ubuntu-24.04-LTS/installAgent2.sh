#!/usr/bin/env bash
set -euo pipefail

############################################################
# 0) Check OS: Ubuntu 24.04 (noble)
############################################################

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  echo "Error: cannot read /etc/os-release."
  exit 1
fi

if ! [[ "$ID" == "ubuntu" && ( "$VERSION_ID" == "24.04" || "${VERSION_CODENAME:-}" == "noble" ) ]]; then
  echo "Error: This installer only supports Ubuntu 24.04 (noble)."
  exit 1
fi

echo "[1/11] OS check OK (Ubuntu 24.04 / noble)."


############################################################
# 1) Set timezone Europe/Amsterdam
############################################################

echo "[2/11] Setting timezone to Europe/Amsterdam..."
sudo timedatectl set-timezone Europe/Amsterdam
sudo timedatectl set-ntp true


############################################################
# 2) Install Zabbix Repository
############################################################

echo "[3/11] Downloading Zabbix 7.4 repository..."
REPO_DEB="zabbix-release_latest_7.4+ubuntu24.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/${REPO_DEB}"

echo "[4/11] Installing Zabbix repository..."
sudo dpkg -i "$REPO_DEB"

echo "[5/11] Updating APT index..."
sudo apt update -y


############################################################
# 3) Install Zabbix Agent 2 + plugins
############################################################

echo "[6/11] Installing Zabbix Agent 2 + plugins..."
sudo apt install -y zabbix-agent2 \
    zabbix-agent2-plugin-mongodb \
    zabbix-agent2-plugin-mssql \
    zabbix-agent2-plugin-postgresql


############################################################
# 4) Ask for Server IP
############################################################

echo
read -rp "Enter the IP address of the Main Zabbix Server (IPv4): " ZBX_SERVER_IP

if ! [[ "$ZBX_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Error: invalid IPv4 address: $ZBX_SERVER_IP"
  exit 1
fi


############################################################
# 4b) Determine hostname identity
############################################################

AGENT_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
echo "[INFO] Using system hostname: ${AGENT_HOSTNAME}"


############################################################
# 5) Paths
############################################################

CONF="/etc/zabbix/zabbix_agent2.conf"
PSK_FILE="/etc/zabbix/psk.key"
LOG_DIR="/var/log/zabbix"


############################################################
# 6) Prepare directories
############################################################

echo "[7/11] Preparing directories..."
sudo install -d -m 0755 /etc/zabbix
sudo install -d -m 0755 "$LOG_DIR"

if id zabbix >/dev/null 2>&1; then
  sudo chown -R zabbix:zabbix "$LOG_DIR"
fi


############################################################
# 7) Generate PSK
############################################################

echo "[8/11] Generating TLS PSK..."

if command -v openssl >/dev/null 2>&1; then
  PSK_VAL="$(openssl rand -hex 32)"
else
  PSK_VAL="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

echo "$PSK_VAL" | sudo tee "$PSK_FILE" >/dev/null
sudo chmod 600 "$PSK_FILE"

# Backup config
[ -e "$CONF" ] && sudo cp -a "$CONF" "${CONF}.bak.$(date +%F_%H%M%S)"


############################################################
# 8) Write agent configuration
############################################################

echo "[9/11] Writing Zabbix Agent 2 configuration..."

sudo tee "$CONF" >/dev/null <<EOF
##### AGENT CONFIG #####
PidFile=/run/zabbix/zabbix_agent2.pid
LogType=file
LogFile=${LOG_DIR}/zabbix_agent2.log
DebugLevel=3

##### SERVER #####
Server=${ZBX_SERVER_IP}
ServerActive=${ZBX_SERVER_IP}
Hostname=${AGENT_HOSTNAME}

##### SECURITY (TLS PSK) #####
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=${AGENT_HOSTNAME}
TLSPSKFile=${PSK_FILE}

##### USER #####
User=zabbix
EOF

sudo chown zabbix:zabbix "$CONF" "$PSK_FILE"


############################################################
# 9) Summary
############################################################

echo
echo "=============================================="
echo "     ZABBIX AGENT 2 REGISTRATION INFORMATION"
echo "=============================================="
echo
echo "Use these values in the Zabbix Frontend:"
echo
echo "Hostname (must match exactly):"
echo "    ${AGENT_HOSTNAME}"
echo
echo "TLS PSK Identity:"
echo "    ${AGENT_HOSTNAME}"
echo
echo "TLS PSK Value:"
echo "    ${PSK_VAL}"
echo
echo "=============================================="
echo "Config File : ${CONF}"
echo "PSK File    : ${PSK_FILE}"
echo "=============================================="


############################################################
# 10) Start + enable service
############################################################

echo "[10/11] Enabling & restarting Zabbix Agent 2..."
sudo systemctl enable zabbix-agent2 --now
sudo systemctl restart zabbix-agent2

echo "[11/11] Done."
systemctl status zabbix-agent2 --no-pager -l || true