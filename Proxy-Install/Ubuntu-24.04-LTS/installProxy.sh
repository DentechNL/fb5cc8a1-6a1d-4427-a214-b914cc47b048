#!/usr/bin/env bash
set -euo pipefail

##############################################
# Helper functions
##############################################
log() { echo -e "$1"; }
asroot() { sudo bash -c "$*"; }

export DEBIAN_FRONTEND=noninteractive


##############################################
# 0) Verify OS is Ubuntu 24.04 (noble)
##############################################
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  echo "ERROR: cannot read /etc/os-release."
  exit 1
fi

if ! [[ "$ID" == "ubuntu" && ( "$VERSION_ID" == "24.04" || "${VERSION_CODENAME:-}" == "noble" ) ]]; then
  echo "ERROR: This installer only supports Ubuntu 24.04 (noble)."
  exit 1
fi

log "[1/12] OS check OK (Ubuntu 24.04 / noble)."


##############################################
# 1) Set timezone (required for Zabbix active proxy)
##############################################
log "[2/12] Setting timezone to Europe/Amsterdam..."
asroot "timedatectl set-timezone Europe/Amsterdam"
asroot "timedatectl set-ntp true || true"


##############################################
# 2) Prepare base system on minimal/cloud-init Ubuntu
#    - Fix broken dpkg states
#    - Ensure required repositories exist
#    - Install base tools (wget, ca-certificates, gnupg)
##############################################
log "[3/12] Preparing package manager and base tools..."

# Repair broken dpkg/apt states (common on cloud images)
asroot "dpkg --configure -a || true"
asroot "apt-get -f install -y || true"
asroot "apt-get update -y || true"

# Ensure essential tools exist
asroot "apt-get install -y --no-install-recommends ca-certificates wget gnupg lsb-release software-properties-common"

# Make sure 'universe' is enabled (required for fping and other deps)
if ! grep -RqsE '^deb .*ubuntu .* universe' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
  asroot "add-apt-repository -y universe"
fi

asroot "apt-get update -y"


##############################################
# 3) Install Zabbix Repository FIRST
#    (Never install zabbix-proxy before repo → causes dependency hell)
##############################################
log "[4/12] Downloading Zabbix 7.4 repository package..."
REPO_DEB="zabbix-release_latest_7.4+ubuntu24.04_all.deb"
wget -q "https://repo.zabbix.com/zabbix/7.4/release/ubuntu/pool/main/z/zabbix-release/${REPO_DEB}"

log "[5/12] Installing Zabbix repository..."
asroot "dpkg -i '$REPO_DEB' || apt-get -f install -y"
asroot "apt-get update -y"


##############################################
# 4) Install Zabbix Proxy (SQLite)
#    (Zabbix repo resolves all correct dependencies)
##############################################
log "[6/12] Installing Zabbix Proxy (SQLite) from Zabbix repo..."
asroot "apt-get install -y --no-install-recommends zabbix-proxy-sqlite3"


##############################################
# 5) Prompt for Zabbix Server IP
##############################################
echo
read -rp "Enter the IP address of the Main Zabbix Server (IPv4): " ZBX_SERVER_IP

if ! [[ "$ZBX_SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "ERROR: invalid IPv4 address: $ZBX_SERVER_IP"
  exit 1
fi


##############################################
# 5b) Determine Proxy Hostname / Identity
##############################################
PROXY_HOSTNAME="$(hostname -f 2>/dev/null || hostname)"
log "[INFO] Using system hostname for identity: ${PROXY_HOSTNAME}"


##############################################
# 6) Define file paths
##############################################
CONF="/etc/zabbix/zabbix_proxy.conf"
PSK_FILE="/etc/zabbix/psk.key"
DB_PATH="/var/lib/zabbix/zabbix_proxy.sqlite3"
LOG_FILE="/var/log/zabbix/zabbix_proxy.log"
OVERRIDE_DIR="/etc/systemd/system/zabbix-proxy.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"


##############################################
# 7) Create directories
##############################################
log "[7/12] Preparing directories..."
asroot "install -d -m 0755 /etc/zabbix /var/lib/zabbix /var/log/zabbix"

if id zabbix >/dev/null 2>&1; then
  asroot "chown -R zabbix:zabbix /var/lib/zabbix /var/log/zabbix"
fi


##############################################
# 8) Generate PSK (runtime secret)
##############################################
log "[8/12] Generating TLS PSK..."

if command -v openssl >/dev/null 2>&1; then
  PSK_VAL="$(openssl rand -hex 32)"
else
  PSK_VAL="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

echo "$PSK_VAL" | asroot "tee '$PSK_FILE' >/dev/null"
asroot "chmod 600 '$PSK_FILE'"


##############################################
# 9) Apply vendor-correct systemd override
#    Zabbix Proxy always forks → use Type=forking
##############################################
log "[9/12] Applying systemd override (Type=forking)..."

asroot "mkdir -p '$OVERRIDE_DIR'"
asroot "tee '$OVERRIDE_FILE' >/dev/null" <<'EOF'
[Service]
Type=forking
PIDFile=/run/zabbix/zabbix_proxy.pid

ExecStart=
ExecStart=/usr/sbin/zabbix_proxy -c /etc/zabbix/zabbix_proxy.conf

ExecStop=
ExecStop=/bin/kill -TERM $MAINPID
EOF

asroot "systemctl daemon-reload"


##############################################
# 10) Write Proxy Configuration File
##############################################
log "[10/12] Writing Zabbix Proxy configuration..."

asroot "bash -c '[[ -e \"$CONF\" ]] && cp -a \"$CONF\" \"${CONF}.bak.$(date +%F_%H%M%S)\" || true'"

asroot "tee '$CONF' >/dev/null" <<EOF
##### ACTIVE PROXY #####
ProxyMode=0
Server=${ZBX_SERVER_IP}
Hostname=${PROXY_HOSTNAME}

##### DATABASE (SQLite) #####
DBName=${DB_PATH}

##### LOGGING #####
LogType=file
LogFile=${LOG_FILE}
DebugLevel=3

##### PERFORMANCE #####
ProxyOfflineBuffer=24
ProxyBufferMode=hybrid
ProxyMemoryBufferSize=16M
ProxyConfigFrequency=30
DataSenderFrequency=1

##### SECURITY (TLS PSK) #####
TLSConnect=psk
TLSPSKIdentity=${PROXY_HOSTNAME}
TLSPSKFile=${PSK_FILE}

##### SYSTEM #####
User=zabbix
EOF

asroot "chown zabbix:zabbix '$CONF' '$PSK_FILE'"

##############################################
# 11) Display Registration Information
##############################################
echo
echo "=============================================="
echo "   ZABBIX PROXY REGISTRATION INFORMATION"
echo "=============================================="
echo
echo "Use these values in the Zabbix Frontend:"
echo
echo "Proxy Name (must match exactly):"
echo "    ${PROXY_HOSTNAME}"
echo
echo "TLS PSK Identity:"
echo "    ${PROXY_HOSTNAME}"
echo
echo "TLS PSK Value:"
if asroot "test -f '$PSK_FILE'"; then
  asroot "cat '$PSK_FILE'"
else
  echo "ERROR: PSK file not found at $PSK_FILE"
fi
echo
echo "=============================================="
echo "Files:"
echo " Config File : ${CONF}"
echo " PSK File    : ${PSK_FILE}"
echo " Override    : ${OVERRIDE_FILE}"
echo "=============================================="

##############################################
# 12) Start Proxy Service
##############################################
log "[12/12] Starting Zabbix Proxy service..."
asroot "systemctl enable zabbix-proxy --now || true"
asroot "systemctl restart zabbix-proxy || true"